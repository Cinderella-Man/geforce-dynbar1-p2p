# shellcheck shell=bash disable=SC2034  # the variables are used by the scripts that source this file
# Sourced by the scripts in this directory: settings, sha256 pins, chips and shared checks.
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
CONFIG=${P2P_CONFIG:-$HERE/config.sh}
# shellcheck source=config.sh
. "$CONFIG" || { echo "ABORT: cannot read $CONFIG"; exit 1; }
# The deprecated contrib/3080-20g/config.sh (one release) documents P2P_ENABLE=1 as the driver default; keep that
# meaning for it.
if [[ $(readlink -f "$CONFIG") == */contrib/3080-20g/config.sh ]] && [ "${P2P_ENABLE:-}" = 1 ]; then
  echo "note: P2P_ENABLE=1 from contrib/3080-20g/config.sh is the driver default there (old meaning); in contrib/config.sh 1 writes RMDynBar1P2PEnable=1 per card" >&2
  P2P_ENABLE=
fi
# valid_bdf <address>: a full PCI address as lspci -D and sysfs write it (0000:01:00.0), nothing else. Only 4-digit
# PCI domains: the 5-digit domains (10000:...) that Intel VMD gives the devices behind it are not supported.
valid_bdf() { [[ $1 =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; }
BDF_FORM="a full PCI address like 0000:01:00.0 (lspci -D; 4-digit PCI domains only, devices behind Intel VMD with domains like 10000: are not supported)"
# shellcheck source=chips.sh
. "$HERE/chips.sh"

SUBDIR=updates/p2p
DEPMOD_CONF=/etc/depmod.d/p2p.conf
P2P_CONF=/etc/modprobe.d/zz-nvidia-p2p.conf
BACKUP_BASE=/var/backups/p2p-modules
KDIR=/lib/modules/$KVER
DEST=$KDIR/$SUBDIR
STATE_DIR=/var/lib/geforce-dynbar1-p2p
PASS_FILE=$STATE_DIR/integrity-pass
# What an integrity PASS needs before p2p-enable.sh accepts it: the default size and its full plan of cases
# (p2p-integrity --selftest prints "cases N" for --max-mib 4096).
GATE_MAXMIB=4096 GATE_CASES=264
GBR_CONF=${GBR_CONF:-/etc/geforce-bar1-resize.conf}
REPORT_URL="https://github.com/noon-at-cgn/geforce-dynbar1-p2p/issues/new?template=compatibility-report.md"
declare -A SHA=()
MODS=()

run() { echo "+ $*"; [ "$DRY" = 1 ] || "$@"; }
die() { echo "ABORT: $*"; exit 1; }
loaded() { [ -d "/sys/module/$1" ]; }
param() { cat "/sys/module/$1/parameters/$2" 2>/dev/null; }

srcv() { cat /sys/module/nvidia/srcversion 2>/dev/null; }
# Module files only: nvidia.ko, .ko.zst, .ko.xz or .ko.gz, not the nvidia.ko.sig and .o files that Ubuntu's
# prebuilt-module packages (linux-signatures-nvidia-<kernel>, linux-objects-nvidia-<branch>-<kernel>) keep in
# kernel/nvidia-<branch>/bits/ and leave behind after a switch to another driver.
KO_RE='\.ko(\.(zst|xz|gz))?'
# Directory of the stock nvidia module for $KVER (anywhere outside updates/p2p); empty if there is none. With modules
# of several branches installed, the one of version $VER wins.
stock_dir() {
  local f first=
  while IFS= read -r f; do
    [ -n "$first" ] || first=$f
    [ "$(modinfo -F version "$f" 2>/dev/null)" = "$VER" ] && { dirname "$f"; return 0; }
  done < <(find "$KDIR" -regextype posix-extended -path "$DEST" -prune -o -regex ".*/nvidia$KO_RE" -print)
  [ -z "$first" ] || dirname "$first"
}
# ko_in <dir> <module>: the module file in dir, compressed or not.
ko_in() { find "$1" -maxdepth 1 -regextype posix-extended -regex ".*/$2$KO_RE" | head -1; }

# --yes or --dry-run, plus the flags a script allows ($1 = space-separated list); sets DRY and FLAGS.
parse_args() {
  local allowed=$1 a; shift
  DRY=; FLAGS=" "
  for a in "$@"; do
    case $a in
      --yes) DRY=0 ;;
      --dry-run) DRY=1 ;;
      *) [[ " $allowed " == *" $a "* ]] || { echo "refusing: unknown argument $a"; exit 2; }; FLAGS+="$a " ;;
    esac
  done
  [ -n "$DRY" ] || { echo "refusing: give --yes (or --dry-run to only print the plan)"; exit 2; }
}
has_flag() { [[ $FLAGS == *" $1 "* ]]; }

preflight_common() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  [ -n "$GPUS" ] || die "set GPUS in $CONFIG"
  local g
  for g in $GPUS; do
    valid_bdf "$g" || die "GPUS: '$g' is not $BDF_FORM"
    [ -e "/sys/bus/pci/devices/$g" ] || die "no PCI device $g"
  done
  case $P2P_ENABLE in ""|0|1) ;; *) die "P2P_ENABLE must be empty, 0 or 1" ;; esac
}
# Every card in GPUS is a chip this driver's P2P route serves (verified or opt-in); used by the scripts that write the
# per-card options.
preflight_chips() {
  local g
  for g in $GPUS; do
    chip_check "$g"
    case $C_CLASS in
      verified) echo "$g: $C_CHIP ($C_IDS), RTX 3080 20GB, verified: P2P on by default" ;;
      default) echo "$g: $C_CHIP ($C_IDS), P2P on by default, untested on this card: run p2p-check.sh --integrity once" ;;
      opt-in) echo "$g: $C_CHIP ($C_IDS), opt-in: P2P only with RMDynBar1P2PEnable=1 for the card (P2P_ENABLE=1 or p2p-enable.sh)" ;;
      stock) die "$g: $C_CHIP is GeForce Blackwell, whose BAR1 P2P NVIDIA's own driver already offers; remove it from GPUS" ;;
      datacenter) die "$g: $C_CHIP is a datacenter chip, not a target of this driver patch; remove it from GPUS" ;;
      *) die "$g: unknown chip ($C_WHY); remove it from GPUS" ;;
    esac
  done
}

# The per-device string, in the format geforce-bar1-resize writes; P2P_ENABLE=0 adds the per-card opt-out and
# P2P_ENABLE=1 the per-card opt-in (needed for the opt-in chips).
dwords() {
  local g
  for g in $GPUS; do
    printf 'pci=%s;RMForceStaticBar1=0;' "$g"
    case $P2P_ENABLE in 0) printf 'RMDynBar1P2PEnable=0;' ;; 1) printf 'RMDynBar1P2PEnable=1;' ;; esac
  done
}
# card_ok <per-device string> <card> [static]: the card's entry has RMForceStaticBar1=0 as the last (effective) value of
# that key and, unless "static" is given, the effective RMDynBar1P2PEnable matches P2P_ENABLE: 0 for 0, 1 for 1, unset
# or 1 for empty (the driver default). Prints what is wrong.
card_ok() {
  local s v
  [[ $1 == *"pci=$2;"* ]] || { echo "no per-device entry for $2"; return 1; }
  s=${1#*"pci=$2;"}; s="${s%%pci=*};"
  [[ $s == *"RMForceStaticBar1=0;"* ]] || { echo "no RMForceStaticBar1=0 for $2"; return 1; }
  v=${s##*RMForceStaticBar1=}; v=${v%%;*}
  [ "$v" = 0 ] || { echo "RMForceStaticBar1=$v for $2 overrides RMForceStaticBar1=0 (last value wins)"; return 1; }
  [ "${3:-}" != static ] || return 0
  v=$(card_key "$1" "$2" RMDynBar1P2PEnable)
  case $P2P_ENABLE in
    0)
      [ "$v" != 0 ] || return 0
      if [[ $s == *"RMDynBar1P2PEnable=0;"* ]]; then echo "RMDynBar1P2PEnable=$v for $2 overrides RMDynBar1P2PEnable=0 (last value wins)"
      else echo "P2P_ENABLE=0 but no RMDynBar1P2PEnable=0 for $2"; fi
      return 1 ;;
    1) [ "$v" = 1 ] || { echo "P2P_ENABLE=1 but RMDynBar1P2PEnable is ${v:-not set} for $2, not 1"; return 1; } ;;
    *) [ -z "$v" ] || [ "$v" = 1 ] || { echo "RMDynBar1P2PEnable=$v set for $2 (P2P off) but P2P_ENABLE is not 0"; return 1; } ;;
  esac
}
nvidia_opts() {
  local o=("NVreg_RegistryDwordsPerDevice=$(dwords)" NVreg_EnableResizableBar=0)
  # shellcheck disable=SC2206  # EXTRA_NVIDIA_OPTS is a space-separated list
  o+=($EXTRA_NVIDIA_OPTS)
  printf '%s\n' "${o[@]}"
}
UVM_OPTS=(uvm_disable_hmm=1)

# Reads <dir>/SHA256SUMS (written by your build) into SHA[module]; nvidia-peermem is optional.
load_pins() {
  local f=$1/SHA256SUMS sum name m
  [ -r "$f" ] || die "$f missing: write it right after the build (README, Build and install)"
  while read -r sum name; do name=${name#\*}; name=${name##*/}; SHA[${name%.ko}]=$sum; done <"$f"
  MODS=(nvidia nvidia-modeset nvidia-drm nvidia-uvm)
  [ -z "${SHA[nvidia-peermem]:-}" ] || MODS+=(nvidia-peermem)
  for m in "${MODS[@]}"; do [ -n "${SHA[$m]:-}" ] || die "$f has no line for $m.ko"; done
}

# Every module in <dir> matches its pin, the kernel and the driver version.
verify_ko() {
  local m f s vm v
  for m in "${MODS[@]}"; do
    f=$1/$m.ko; [ -f "$f" ] || die "missing $f"
    s=$(sha256sum "$f" | cut -d' ' -f1)
    [ "$s" = "${SHA[$m]}" ] || die "$f sha256 does not match SHA256SUMS:
  sha256 $s
  pinned ${SHA[$m]}"
    vm=$(modinfo -F vermagic "$f" | cut -d' ' -f1); v=$(modinfo -F version "$f")
    [ "$vm" = "$KVER" ] && [ "$v" = "$VER" ] || die "$f: vermagic $vm version $v, want $KVER $VER"
    echo "$f sha256 ok, version $v, vermagic $vm"
  done
}

holders() {
  local fd t p
  for fd in /proc/[0-9]*/fd/*; do
    t=$(readlink "$fd" 2>/dev/null)
    case $t in /dev/nvidia*|/dev/dri/*) p=${fd#/proc/}; p=${p%%/*}; echo "$p $(cat "/proc/$p/comm" 2>/dev/null) $t" ;; esac
  done | sort -u
}
# Kernel-log events and the P2P route's own counters; compared before and after a swap or an integrity run.
# events [address...]: with addresses, only the Xid and DynBar1P2P lines that name one of those cards count (other
# GPUs in the machine log their own refusals and errors); AER, DMAR, RmInitAdapter and the counters always count.
# shellcheck disable=SC2120  # the addresses are optional; p2p-load and p2p-rollback count every card
events() {
  local k d s rx='NVRM: Xid' rd='DynBar1P2P:'
  k=$(dmesg 2>/dev/null)
  if [ $# -gt 0 ]; then
    rx='' rd=''
    for d in "$@"; do s=${d%.*}; rx+="${rx:+|}NVRM: Xid \\(PCI:$s\\)"; rd+="${rd:+|}DynBar1P2P: GPU $s:"; done
  fi
  echo "Xid $(grep -cE "$rx" <<<"$k") AER $(grep -cE 'AER: (Corrected|Uncorrected|Multiple)' <<<"$k") DMAR $(grep -cE 'DMAR: \[DMA' <<<"$k") RmInitAdapter $(grep -c RmInitAdapter <<<"$k")" \
    "DynBar1P2P $(grep -cE "$rd" <<<"$k") uvm_bar1_gate_trips $(param nvidia_uvm uvm_bar1_gate_trips) nv_dynbar1_rm_p2p_refused $(param nvidia nv_dynbar1_rm_p2p_refused)"
}

# GSP firmware. For every GPU it initializes, the open driver loads nvidia/<version>/gsp_<family>.bin and
# ucodes_<family>.bin through the kernel's firmware loader (chip_fw_files). Without them RM init fails on every GPU.
# fw_files: the files that the cards in GPUS and the GPUs nvidia drives now need.
fw_files() {
  local g d c
  for g in $GPUS /sys/bus/pci/drivers/nvidia/????:??:??.?; do
    d=$(rd "/sys/bus/pci/devices/${g##*/}/device") || continue
    if c=$(chip_of_device "$d"); then chip_fw_files "$c" | tr ' ' '\n'; fi
  done | sort -u
}
# fw_dirs <kernel> [boot]: where the firmware loader looks, in its order: firmware_class.path (the running value; with
# "boot", the one on the kernel command line, which is what the next boot uses), then /lib/firmware/updates/<kernel>,
# /lib/firmware/updates, /lib/firmware/<kernel>, /lib/firmware.
fw_dirs() {
  local p
  if [ "${2:-}" = boot ]; then p=$(tr ' ' '\n' </proc/cmdline | sed -n 's/^firmware_class\.path=//p' | tail -1)
  else p=$(cat /sys/module/firmware_class/parameters/path 2>/dev/null); fi
  [ -z "$p" ] || echo "$p"
  printf '%s\n' "/lib/firmware/updates/$1" /lib/firmware/updates "/lib/firmware/$1" /lib/firmware
}
# fw_check <kernel> [boot]: refuses unless every file of fw_files is in a fw_dirs directory under nvidia/$VER/
# (uncompressed, .xz or .zst).
fw_check() {
  local f d x miss="" dirs
  mapfile -t dirs < <(fw_dirs "$@")
  for f in $(fw_files); do
    for d in "${dirs[@]}"; do
      for x in "" .xz .zst; do
        [ -e "$d/nvidia/$VER/$f$x" ] && { echo "GSP firmware: $d/nvidia/$VER/$f$x"; continue 3; }
      done
    done
    miss+=" nvidia/$VER/$f"
  done
  [ -z "$miss" ] || die "GSP firmware not found:$miss
Looked in: ${dirs[*]}${2:+
firmware_class.path counts only when it is on the kernel command line.}
Without it RM init fails on every GPU. Install the firmware of the $VER driver, e.g. the firmware/ directory of
NVIDIA-Linux-x86_64-$VER.run (sh NVIDIA-Linux-x86_64-$VER.run -x),
copied to /lib/firmware/nvidia/$VER/. Nothing changed."
}

# The last kernel-log line now; klog_since <that line> prints what the kernel logged after it (everything when the
# line is gone from the log).
klog_mark() { dmesg 2>/dev/null | tail -1; }
klog_since() {
  dmesg 2>/dev/null | M=$1 awk 'ENVIRON["M"] != "" && $0 == ENVIRON["M"] { n = NR } { l[NR] = $0 } END { for (i = n + 1; i <= NR; i++) print l[i] }'
}
# rm_init_failed <mark>: the lines since the mark that say RM init failed on a GPU. The module stays loaded when that
# happens (kernel-open/nvidia/nv-pci.c logs "init failed during probe" and keeps the device).
rm_init_failed() { klog_since "$1" | grep -E 'RmInitAdapter failed|init failed during probe'; }

# Runs DRAIN_CMD, then waits up to 10 s for the GPUs to have no holders. Refuses (nothing unloaded) otherwise.
drain() {
  local h i
  [ -z "$DRAIN_CMD" ] || run sh -c "$DRAIN_CMD"
  for i in 1 2 3; do h=$(holders); [ -z "$h" ] || [ "$DRY" = 1 ] && break; [ "$i" = 3 ] || sleep 5; done
  [ -z "$h" ] && { echo "holders: none"; return 0; }
  echo "holders:"; echo "$h"
  [ "$DRY" = 1 ] && { echo "(dry run: --yes refuses while these hold the GPUs)"; return 0; }
  die "GPUs still held; nothing unloaded"
}
restore_services() { [ -z "$RESTORE_CMD" ] || run sh -c "$RESTORE_CMD"; }

# Pause udev (so no rule reloads a module mid-swap) and detach the console; undone by unpause, or by the trap.
pause() {
  trap unpause EXIT
  run udevadm control --stop-exec-queue || die "cannot pause udev"
  [ -z "$VTCON" ] || { echo "+ echo 0 > $VTCON"; [ "$DRY" = 1 ] || echo 0 >"$VTCON"; }
}
unpause() {
  trap - EXIT
  run udevadm control --start-exec-queue; run udevadm settle -t 30
  [ -z "$VTCON" ] || { echo "+ echo 1 > $VTCON"; [ "$DRY" = 1 ] || echo 1 >"$VTCON"; }
}
# stop_blocked <what failed> <what the next boot loads>: the stop after a failed RM init (or a failed load) while udev
# is paused. When udev resumes it runs the events it held back since pause, and rules may load nvidia on them (e.g. a
# 70-nvidia.rules that runs nvidia-modprobe -u and nvidia-smi -L on any nvidia event). So first block every nvidia
# module in /run/modprobe.d (runtime only: the reboot clears it), then resume udev (unpause settles with a timeout),
# report what lsmod shows and stop.
STOP_CONF=/run/modprobe.d/zz-p2p-stop-nvidia.conf
stop_blocked() {
  local m l
  echo "+ write $STOP_CONF: install <module> /bin/false for every nvidia module"
  { mkdir -p "${STOP_CONF%/*}" && for m in nvidia nvidia_uvm nvidia_modeset nvidia_drm nvidia_peermem \
      nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem; do echo "install $m /bin/false"; done >"$STOP_CONF"; } ||
    echo "WARNING: could not write $STOP_CONF; udev may load nvidia again"
  unpause
  l=$(lsmod | grep '^nvidia')
  echo "lsmod after udev resumed:"; echo "${l:-  no nvidia module}"
  local why="The next boot loads $2:
if that is the driver that failed here, it fails the same way unless the cause (e.g. missing or unusable GSP
firmware, see the kernel log above) is fixed first.
$STOP_CONF is in /run, so the reboot removes it"
  [ -z "$l" ] || die "$1; the nvidia modules above are STILL LOADED.
Do not use the GPUs; reboot now. Until then $STOP_CONF blocks loading any more nvidia modules.
$why."
  die "$1; no nvidia driver is loaded.
$STOP_CONF blocks every nvidia module until the reboot.
$why.
To retry without a reboot once the cause is fixed, remove the block by hand: rm $STOP_CONF"
}
unload_stack() {
  local m
  for m in nvidia_peermem nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
    loaded "$m" || continue
    run rmmod "$m" || return 1
  done
}

# "<module> <file>" for each module as modules.dep resolves it.
resolution() {
  local m f
  for m in "${MODS[@]}"; do
    f=$(awk -F: -v m="$m" '
      {
        p = $1
        for (i = 0; i < 4; i++) {
          ext = (i == 0 ? "" : i == 1 ? ".zst" : i == 2 ? ".xz" : ".gz")
          suffix = "/" m ".ko" ext
          if (length(p) >= length(suffix) &&
              substr(p, length(p) - length(suffix) + 1) == suffix) {
            print p
            exit
          }
        }
      }
    ' "$KDIR/modules.dep")
    echo "$m ${f:-MISSING}"
  done
}

# The per-device string modprobe passes at the next load of nvidia (the last such option wins), and the one the
# running driver uses (empty when nvidia is not loaded).
boot_pd() { modprobe -c 2>/dev/null | awk '$1 == "options" && $2 == "nvidia"' | grep -o 'NVreg_RegistryDwordsPerDevice=[^ ]*' | tail -1; }
live_pd() { grep -E '^RegistryDwordsPerDevice:' /proc/driver/nvidia/params 2>/dev/null; }

# The per-device option modprobe reads passes card_ok for every card; $1 = static checks RMForceStaticBar1=0 only.
per_device_configured() {
  local s g ok=0
  s=$(boot_pd)
  for g in $GPUS; do card_ok "$s" "$g" "${1:-}" || ok=1; done
  return $ok
}

# pairs <address>...: every unordered pair, one "A B" per line, in the order given.
pairs() {
  local i j a=("$@")
  for ((i = 0; i < ${#a[@]}; i++)); do for ((j = i + 1; j < ${#a[@]}; j++)); do echo "${a[i]} ${a[j]}"; done; done
}
