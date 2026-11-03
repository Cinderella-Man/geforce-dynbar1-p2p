# shellcheck shell=bash disable=SC2034  # the variables are used by the scripts that source this file
# Sourced by the scripts in this directory: settings, sha256 pins and shared checks.
HERE=$(dirname "$(readlink -f "$0")")
# shellcheck source=config.sh
. "${P2P_CONFIG:-$HERE/config.sh}"

SUBDIR=updates/p2p
DEPMOD_CONF=/etc/depmod.d/p2p.conf
P2P_CONF=/etc/modprobe.d/zz-nvidia-p2p.conf
BACKUP_BASE=/var/backups/p2p-modules
KDIR=/lib/modules/$KVER
DEST=$KDIR/$SUBDIR
declare -A SHA=()
MODS=()

run() { echo "+ $*"; [ "$DRY" = 1 ] || "$@"; }
die() { echo "ABORT: $*"; exit 1; }
loaded() { [ -d "/sys/module/$1" ]; }
param() { cat "/sys/module/$1/parameters/$2" 2>/dev/null; }

srcv() { cat /sys/module/nvidia/srcversion 2>/dev/null; }
# Directory of the stock nvidia module for $KVER (anywhere outside updates/p2p); empty if there is none.
stock_dir() { local f; f=$(find "$KDIR" -path "$DEST" -prune -o -name 'nvidia.ko*' -print | head -1); [ -z "$f" ] || dirname "$f"; }
# ko_in <dir> <module>: the module file in dir, compressed or not.
ko_in() { find "$1" -maxdepth 1 -name "$2.ko*" | head -1; }

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
  [ -n "$GPUS" ] || die "set GPUS in $HERE/config.sh"
  local g
  for g in $GPUS; do [ -e "/sys/bus/pci/devices/$g" ] || die "no PCI device $g"; done
  case $P2P_ENABLE in ""|0|1) ;; *) die "P2P_ENABLE must be empty, 0 or 1" ;; esac
}

# The per-device string, in the format geforce-bar1-resize writes; P2P_ENABLE=0 adds the per-card opt-out.
dwords() {
  local g
  for g in $GPUS; do
    printf 'pci=%s;RMForceStaticBar1=0;' "$g"; [ "$P2P_ENABLE" != 0 ] || printf 'RMDynBar1P2PEnable=0;'
  done
}
# card_ok <per-device string> <card> [static]: the card's entry has RMForceStaticBar1=0 as the last (effective) value of
# that key and, unless "static" is given, RMDynBar1P2PEnable=0 exactly when P2P_ENABLE=0. Prints what is wrong.
card_ok() {
  local s v
  [[ $1 == *"pci=$2;"* ]] || { echo "no per-device entry for $2"; return 1; }
  s=${1#*"pci=$2;"}; s="${s%%pci=*};"
  [[ $s == *"RMForceStaticBar1=0;"* ]] || { echo "no RMForceStaticBar1=0 for $2"; return 1; }
  v=${s##*RMForceStaticBar1=}; v=${v%%;*}
  [ "$v" = 0 ] || { echo "RMForceStaticBar1=$v for $2 overrides RMForceStaticBar1=0 (last value wins)"; return 1; }
  if [ "${3:-}" = static ]; then return 0
  elif [ "$P2P_ENABLE" = 0 ]; then
    [[ $s == *"RMDynBar1P2PEnable=0;"* ]] || { echo "P2P_ENABLE=0 but no RMDynBar1P2PEnable=0 for $2"; return 1; }
  else
    [[ $s != *"RMDynBar1P2PEnable=0;"* ]] || { echo "RMDynBar1P2PEnable=0 set for $2 (P2P off) but P2P_ENABLE is not 0"; return 1; }
  fi
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
events() {
  local k; k=$(dmesg 2>/dev/null)
  echo "Xid $(grep -c 'NVRM: Xid' <<<"$k") AER $(grep -cE 'AER: (Corrected|Uncorrected|Multiple)' <<<"$k") DMAR $(grep -cE 'DMAR: \[DMA' <<<"$k") RmInitAdapter $(grep -c RmInitAdapter <<<"$k")"
}

# GSP firmware. For every GPU it initializes, the open driver loads nvidia/<version>/gsp_<family>.bin and
# ucodes_<family>.bin through the kernel's firmware loader (kernel-open/common/inc/nv-firmware.h: family tu10x for
# Turing and GA100, ga10x from GA102 on). Without them RM init fails on every GPU. fw_files: the files that the cards in
# GPUS and the GPUs nvidia drives now need.
fw_files() {
  local g d
  for g in $GPUS /sys/bus/pci/drivers/nvidia/????:??:??.?; do
    d=$(cat "/sys/bus/pci/devices/${g##*/}/device" 2>/dev/null) || continue
    if [ "$((d))" -ge $((0x2200)) ]; then printf '%s\n' gsp_ga10x.bin ucodes_ga10x.bin
    elif [ "$((d))" -ge $((0x1e00)) ]; then printf '%s\n' gsp_tu10x.bin ucodes_tu10x.bin; fi
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
    f=$(awk -F: -v m="/$m.ko" '{ n = length($1) - length(m) + 1 } n > 0 && substr($1, n) == m { print $1; exit }' "$KDIR/modules.dep")
    echo "$m ${f:-MISSING}"
  done
}

# The per-device option modprobe reads passes card_ok for every card; $1 = static checks RMForceStaticBar1=0 only.
per_device_configured() {
  local s g ok=0
  s=$(modprobe -c 2>/dev/null | awk '$1 == "options" && $2 == "nvidia"' | grep -o 'NVreg_RegistryDwordsPerDevice=[^ ]*' | tail -1)
  for g in $GPUS; do card_ok "$s" "$g" "${1:-}" || ok=1; done
  return $ok
}
