#!/bin/bash
# shellcheck disable=SC2317,SC2329,SC2016,SC2086 # helpers run through check; stand-in bodies and inner bash -c code expand later; card addresses never need quoting
# SPDX-License-Identifier: MIT
# Stand-in tests of the scripts in contrib/: chip detection, pair verdicts, card_ok (the contract geforce-bar1-resize's
# tests rely on), the old contrib/3080-20g/ entry points, p2p-check.sh (--pairs, the check, --integrity), p2p-enable.sh,
# the p2p-load.sh plan, its GSP firmware gate, its stop after an RM init failure and its handover to p2p-rollback.sh
# with udev paused, p2p-install.sh's firmware gate and the integrity build script, against a fake /sys tree, a fake
# /lib/firmware, a fake nvidia-smi, modprobe -c, modinfo, dmesg and geforce-bar1-resize. No GPU, driver or real system
# file is touched; nothing is written outside $WORK.
#
# Usage, from the repository root, as a normal user:  tests/contrib/run.sh [CASE-PREFIX...]
# Needs bash, coreutils, sed, awk, diff. Optional: shellcheck (case 90), nvcc (case 91 compiles p2p-integrity.cu and
# runs its host-only --selftest; NVCC=/path/to/nvcc, else PATH and /usr/local/cuda*), a pci.ids file (case 01 checks
# the chip table against it; PCI_IDS=/path, else /usr/share/misc/pci.ids or /usr/share/hwdata/pci.ids).
# Environment: WORK (scratch and logs; default a new mktemp -d directory, removed when every case passes).
# Output: one PASS/FAIL/SKIP line per case. Exit status: the number of failed cases (at most 125).
#
# How the scripts see the fake tree: they run as copies in $WORK/src in which only these paths are rewritten to
# $WORK/fake/...: /sys/, /proc/driver/nvidia/, /proc/cmdline, /lib/modules/, /lib/firmware, /var/lib/geforce-dynbar1-p2p,
# /var/backups/, /etc/geforce-bar1-resize.conf, /run/modprobe.d and /usr/local/cuda (checked by reversing it). $WORK/bin
# comes first in PATH: `id -u` prints 0, nvidia-smi, modprobe, modinfo, dmesg, lspci, lsmod, udevadm, rmmod, insmod and
# geforce-bar1-resize are stand-ins. insmod, rmmod and modprobe (loading) keep /sys/module up to date; a module's insmod
# appends $FAKE/klog-<module> (if there is one) to the kernel log; udevadm calls go to $FAKE/udev.
set -u
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)
PUB=$(cd "$HERE/../.." && pwd) || exit 2
ONLY=("$@")
REAL_PATH=$PATH REAL_ID=$(type -P id) REAL_UNAME=$(type -P uname)
for t in sed awk diff sha256sum; do command -v "$t" >/dev/null || { echo "tests/contrib/run.sh needs $t" >&2; exit 2; }; done
OWN_WORK=0
if [ -z "${WORK:-}" ]; then WORK=$(mktemp -d "${TMPDIR:-/tmp}/p2p-contrib-tests.XXXXXX") && OWN_WORK=1 || exit 2; fi
[[ $WORK != *[\|\&\\]* ]] || { echo "WORK must not contain | & or \\" >&2; exit 2; }
if [ "$OWN_WORK" = 0 ] && [ -e "$WORK" ]; then
  [ -e "$WORK/.standins" ] || [ -z "$(ls -A "$WORK")" ] || { echo "$WORK exists and is not an earlier run; not wiping it" >&2; exit 2; }
  rm -rf "${WORK:?}"/* "$WORK/.standins"
fi
mkdir -p "$WORK/bin" "$WORK/cases" && touch "$WORK/.standins"
WORK=$(cd "$WORK" && pwd -P)
FAKE=$WORK/fake SRC=$WORK/src BIN=$WORK/bin
export FAKE GBR_CONF=$FAKE/etc/geforce-bar1-resize.conf

# --- copies with only the system paths substituted ---------------------------------------------------------------------
PATHS=(/sys/ /proc/driver/nvidia/ /proc/cmdline /lib/modules/ /lib/firmware /var/lib/geforce-dynbar1-p2p /var/backups/ /etc/geforce-bar1-resize.conf /run/modprobe.d /usr/local/cuda)
subst() { local a=() p; for p in "${PATHS[@]}"; do a+=(-e "s|$p|$FAKE$p|g"); done; sed "${a[@]}" "$1"; }
unsubst() { local a=() p; for p in "${PATHS[@]}"; do a+=(-e "s|$FAKE$p|$p|g"); done; sed "${a[@]}" "$1"; }
mkdir -p "$SRC"
cp -r "$PUB/contrib" "$SRC/"
rm -f "$SRC/contrib/integrity/p2p-integrity"
while read -r f; do
  subst "$PUB/$f" >"$SRC/$f"
  unsubst "$SRC/$f" | cmp -s - "$PUB/$f" || { echo "substitution is not reversible in $f" >&2; exit 2; }
done < <(cd "$PUB" && find contrib -name '*.sh')
echo "copies of contrib/*.sh in $SRC: $(grep -rl "$FAKE/" "$SRC/contrib" | wc -l) file(s) with substituted paths"

# --- stand-ins -----------------------------------------------------------------------------------------------------
stub() { printf '#!/bin/bash\n%s\n' "$2" >"$BIN/$1" && chmod 755 "$BIN/$1"; }
stub id "[ \"\${1:-}\" = -u ] && { echo 0; exit 0; }; exec $REAL_ID \"\$@\""
stub uname "[ \"\$*\" = -r ] && { echo stand-in; exit 0; }; exec $REAL_UNAME \"\$@\""
stub dmesg 'cat "$FAKE/dmesg" 2>/dev/null; exit 0'
stub udevadm 'echo "udevadm $*" >>"$FAKE/udev"'
stub lsmod 'echo "Module Size Used by"; for d in "$FAKE"/sys/module/*/; do [ -d "$d" ] && echo "$(basename "$d") 1 0"; done; exit 0'
# modload MODULE SRCVERSION: the module is loaded (/sys/module/<name> with the parameters p2p-load.sh checks); its
# kernel-log lines in $FAKE/klog-<name>, if any, go to the log
cat >"$BIN/modload" <<'EOF'
#!/bin/bash
m=${1//-/_}; d=$FAKE/sys/module/$m
mkdir -p "$d/parameters"; echo "$2" >"$d/srcversion"
case $m in
  nvidia) for p in nv_dynbar1_calib nv_dynbar1_delta nv_dynbar1_rm_p2p_refused; do echo 0 >"$d/parameters/$p"; done ;;
  nvidia_uvm) echo Y >"$d/parameters/uvm_disable_hmm"; echo 0 >"$d/parameters/uvm_bar1_gate_trips" ;;
esac
[ ! -e "$FAKE/klog-$m" ] || cat "$FAKE/klog-$m" >>"$FAKE/dmesg"
EOF
chmod 755 "$BIN/modload"
stub rmmod 'echo "rmmod $*" >>"$FAKE/calls"; rm -rf "$FAKE/sys/module/$1"'
stub insmod 'echo "insmod $*" >>"$FAKE/calls"; f=${1##*/}; modload "${f%.ko}" "$(sed -n "s/^srcversion=//p" "$1")"'
stub lspci 'echo "	Region 1: Memory at 6000000000 (64-bit, prefetchable) [size=32G]"'
stub modprobe '[ "${1:-}" = -c ] && { cat "$FAKE/modprobe-c" 2>/dev/null; exit 0; }; echo "modprobe $*" >>"$FAKE/calls"
for a in "$@"; do case $a in nvidia | nvidia_drm | nvidia_uvm) modload "$a" "STOCK-${a//_/-}" ;; esac; done'
# modinfo: the fake .ko files are "field=value" lines; -k KVER -F filename <name> names the stock file.
stub modinfo 'f=""; k=""; n=""
while [ $# -gt 0 ]; do case $1 in -F) f=$2; shift ;; -k) k=$2; shift ;; *) n=$1 ;; esac; shift; done
if [ "$f" = filename ]; then echo "$FAKE/lib/modules/$k/kernel/drivers/video/$n.ko"; exit 0; fi
sed -n "s/^$f=//p" "$n"'
# nvidia-smi: per card $FAKE/smi/<address> (index= arch= vram= bar1=), the topology matrix in $FAKE/smi/topo; with
# $FAKE/smi/off it fails as without a driver.
cat >"$BIN/nvidia-smi" <<'EOF'
#!/bin/bash
S=$FAKE/smi
[ ! -e "$S/off" ] || { echo "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver."; exit 9; }
get() { sed -n "s/^$2=//p" "$S/$1" 2>/dev/null; }
i="" prev=""
for a in "$@"; do [ "$prev" != -i ] || i=$a; prev=$a; done
cards() { for f in "$S"/0*; do [ -e "$f" ] && echo "$(get "${f##*/}" index) ${f##*/}"; done | sort -n; }
case " $* " in
  *" topo -p2p "*) cat "$S/topo" ;;
  *" topo -m "*) echo "        GPU0    GPU1"; echo "GPU0     X      SYS" ;;
  *"--query-gpu=index,pci.bus_id --format=csv,noheader"*) cards | while read -r n b; do echo "$n, 0000${b^^}"; done ;;
  *"--query-gpu=index,pci.bus_id,name"*) echo "index, pci.bus_id, name"; cards | while read -r n b; do echo "$n, 0000${b^^}, Fake GPU"; done ;;
  *"--query-gpu=memory.total"*) [ -e "$S/$i" ] || exit 6; get "$i" vram ;;
  *"--query-gpu=uuid"*) [ -e "$S/$i" ] || exit 6; printf 'GPU-%08d-0000-0000-0000-%012d\n' "$(get "$i" index)" "$(get "$i" index)" ;;
  *" -d MEMORY "*) [ -e "$S/$i" ] || exit 6
    printf 'FB Memory Usage\n    Total : %s MiB\n    Used : 1 MiB\nBAR1 Memory Usage\n    Total : %s MiB\n    Used : 2 MiB\n' \
      "$(get "$i" vram)" "$(get "$i" bar1)" ;;
  *" -q "*) [ -e "$S/$i" ] || exit 6; echo "    Product Architecture                  : $(get "$i" arch)" ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$BIN/nvidia-smi"
# geforce-bar1-resize driver-option --write: one per-device line for the cards in $FAKE/gbr-cards, RMForceStaticBar1=0
# first where the driver option applies (DRIVER_OPTION / driver_option=), then keys= of the card's CARD[] entry
# (address when its ids= match, then vendor:device/sub, then vendor:device; docs/configuration.md and
# docs/driver-option.md of geforce-bar1-resize).
cat >"$BIN/geforce-bar1-resize" <<'EOF'
#!/bin/bash
case "$*" in "driver-option --write") mode=write ;; "driver-option --print") mode=print ;; *) exit 2 ;; esac
echo "geforce-bar1-resize $*" >>"$FAKE/calls"
declare -A CARD=()
. "${GBR_CONF:?}"
# DRIVER_OPTION=auto (the default): RMForceStaticBar1=0 only for cards enlarged through 0x610; on: every enlarged card;
# per card driver_option=on|off wins. $FAKE/gbr-cards: "<address> <route>" per card in its scope: 0x610, resize, or
# large (the firmware's BAR1 is already large enough); only 0x610 gets RMForceStaticBar1=0 under auto.
line=""
while read -r b route; do
  [ -n "$b" ] || continue
  d=$FAKE/sys/bus/pci/devices/$b
  ids="$(cat "$d/vendor"):$(cat "$d/device")/$(cat "$d/subsystem_vendor"):$(cat "$d/subsystem_device")"; ids=${ids//0x/}
  e=""
  if [ -n "${CARD[$b]+x}" ]; then
    w=$(tr ' ' '\n' <<<"${CARD[$b]}" | sed -n 's/^ids=//p')
    [ -z "$w" ] || [ "$w" = "$ids" ] || [ "$w" = "${ids%%/*}" ] && e=${CARD[$b]}
  fi
  [ -n "$e" ] || e=${CARD[$ids]:-${CARD[${ids%%/*}]:-}}
  k=$(tr ' ' '\n' <<<"$e" | sed -n 's/^keys=//p')
  o=$(tr ' ' '\n' <<<"$e" | sed -n 's/^driver_option=//p')
  o=${o:-${DRIVER_OPTION:-auto}}
  s=""
  { [ "$o" = on ] || { [ "$o" = auto ] && [ "${route:-0x610}" = 0x610 ]; }; } && s="RMForceStaticBar1=0;"
  [ -z "$s$k" ] || line+="pci=$b;$s$k"
done <"$FAKE/gbr-cards"
# --print: what --write would write, on stdout, then (as geforce-bar1-resize does) a line for each foreign per-device
# line ($FAKE/gbr-foreign holds one); --write fails after writing when $FAKE/gbr-write-fails exists
out="options nvidia NVreg_RegistryDwordsPerDevice=\"$line\""
[ "$mode" = write ] || { echo "$out"; [ ! -e "$FAKE/gbr-foreign" ] || echo "foreign NVreg_RegistryDwordsPerDevice line in /etc/modprobe.d/other.conf: $(cat "$FAKE/gbr-foreign")"; exit 0; }
echo "$out" >"$FAKE/modprobe-c"
[ ! -e "$FAKE/gbr-write-fails" ] || { [ ! -e "$FAKE/gbr-eat-backup" ] || rm -f "$FAKE"/var/backups/geforce-dynbar1-p2p/*/geforce-bar1-resize.conf; exit 1; }
EOF
chmod 755 "$BIN/geforce-bar1-resize"
export PATH=$BIN:$REAL_PATH GBR_OPT_FILE=$FAKE/modprobe-c

# --- fake system ---------------------------------------------------------------------------------------------------
reset_fake() {
  rm -rf "$FAKE"; mkdir -p "$FAKE/sys/bus/pci/devices" "$FAKE/sys/module" "$FAKE/smi" "$FAKE/proc/driver/nvidia" "$FAKE/etc"
  : >"$FAKE/dmesg"; : >"$FAKE/modprobe-c"; : >"$FAKE/calls"; : >"$FAKE/gbr-cards"; : >"$FAKE/proc/cmdline"; : >"$FAKE/udev"
  fw "$FAKE/lib/firmware" gsp_ga10x.bin ucodes_ga10x.bin gsp_tu10x.bin ucodes_tu10x.bin
  printf '%s\n' "| 0    X     OK" >"$FAKE/smi/topo"
}
# the udevadm calls so far, |-separated; the file stop_blocked writes to block every nvidia module
udev_calls() { tr '\n' '|' <"$FAKE/udev"; }
STOP=$FAKE/run/modprobe.d/zz-p2p-stop-nvidia.conf
# fw DIR FILE...: GSP firmware files of 615.71.09 under DIR/nvidia/615.71.09/
fw() { local d=$1/nvidia/615.71.09 f; shift; mkdir -p "$d"; for f in "$@"; do echo fw >"$d/$f"; done; }
# card ADDRESS DEVICE [ARCH] [VRAM_MIB] [BAR1_MIB] [CLASS] [SUBSYSTEM]: an NVIDIA function; ARCH "-" = not in nvidia-smi.
card() {
  local b=$1 dev=$2 arch=${3:-Ampere} vram=${4:-20480} bar=${5:-32768} cls=${6:-0x030000} sub=${7:-0x146d}
  local d=$FAKE/sys/bus/pci/devices/$b n
  mkdir -p "$d" "$FAKE/sys/bus/pci/drivers/nvidia"
  echo 0x10de >"$d/vendor"; echo "0x$dev" >"$d/device"; echo "$cls" >"$d/class"
  echo 0x10de >"$d/subsystem_vendor"; echo "$sub" >"$d/subsystem_device"
  printf '0x00000000f0000000 0x00000000f0ffffff 0x0000000000040200\n0x0000006000000000 0x%016x 0x000000000014220c\n' \
    $((0x6000000000 + (bar << 20) - 1)) >"$d/resource"
  ln -sfn ../../drivers/nvidia "$d/driver"
  n=$(find "$FAKE/smi" -name '0*' | wc -l)
  [ "$arch" = - ] || printf 'index=%s\narch=%s\nvram=%s\nbar1=%s\n' "$n" "$arch" "$vram" "$bar" >"$FAKE/smi/$b"
}
# topo A B CELL: a two-card -p2p matrix (both cards in smi index order).
topo() { printf '        GPU0    GPU1\nGPU0     X      %s\nGPU1     %s      X\n\nLegend:\n  X    = Self\n  OK   = Status Ok\n' "$1" "$1" >"$FAKE/smi/topo"; }
# params PER-DEVICE-STRING: the running driver's parameters and module state (the patched build loaded).
params() {
  local m
  printf 'RegistryDwords: ""\nRegistryDwordsPerDevice: "%s"\nEnableResizableBar: 0\n' "$1" >"$FAKE/proc/driver/nvidia/params"
  echo "NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  615.71.09  Release Build" >"$FAKE/proc/driver/nvidia/version"
  for m in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do mkdir -p "$FAKE/sys/module/$m/parameters"; echo "SRC-$m" >"$FAKE/sys/module/$m/srcversion"; done
  for p in nv_dynbar1_calib nv_dynbar1_delta nv_hugetlb_pin_fast_path nv_dynbar1_rm_p2p_refused; do echo 0 >"$FAKE/sys/module/nvidia/parameters/$p"; done
  echo Y >"$FAKE/sys/module/nvidia_uvm/parameters/uvm_disable_hmm"; echo 615.71.09 >"$FAKE/sys/module/nvidia/version"
  for p in uvm_bar1_gate_trips uvm_bar1_gate_pairs; do echo 0 >"$FAKE/sys/module/nvidia_uvm/parameters/$p"; done
}
# build OUT: fake .ko files of the patched build with SHA256SUMS; kver stand-in.
fake_build() {
  local m o=$WORK/out
  mkdir -p "$o"
  for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
    printf 'srcversion=SRC-%s\nvermagic=stand-in SMP\nversion=615.71.09\ndepends=\n' "${m//-/_}" >"$o/$m.ko"
  done
  (cd "$o" && sha256sum nvidia*.ko >SHA256SUMS)
  mkdir -p "$FAKE/lib/modules/stand-in/kernel/drivers/video"
  for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
    printf 'srcversion=STOCK-%s\nvermagic=stand-in SMP\nversion=615.71.09\ndepends=\n' "$m" >"$FAKE/lib/modules/stand-in/kernel/drivers/video/$m.ko"
  done
}
modprobe_line() { echo "options nvidia NVreg_RegistryDwordsPerDevice=\"$1\"" >"$FAKE/modprobe-c"; }
# cfg GPUS P2P_ENABLE: the case's settings, then the defaults of contrib/config.sh.
cfg() { printf 'GPUS="%s"\nOUT=%s\nKVER=stand-in\nP2P_ENABLE=%s\n. "%s"\n' "$1" "$WORK/out" "$2" "$SRC/contrib/config.sh" >"$CDIR/config.sh"; }

# --- runners and checks ----------------------------------------------------------------------------------------------
# sh SCRIPT ARGS...: run contrib/SCRIPT (copy) with $CDIR/config.sh; output in $CDIR/out, status in RC.
sh_() {
  local s=$1; shift
  echo "\$ $s $*" >>"$LOG"
  RC=0
  P2P_CONFIG=$CDIR/config.sh GBR_CONF=$FAKE/etc/geforce-bar1-resize.conf "$SRC/contrib/$s" "$@" </dev/null >"$CDIR/out" 2>&1 || RC=$?
  sed 's/^/  | /' "$CDIR/out" >>"$LOG"; echo "  rc=$RC" >>"$LOG"
}
# lib 'commands': run commands with contrib/common.sh sourced; output in $CDIR/out.
lib() {
  echo "\$ lib: $1" >>"$LOG"
  RC=0
  # shellcheck disable=SC2016 # expanded by the inner bash
  P2P_CONFIG=$CDIR/config.sh bash -c '. "$1/contrib/common.sh"; eval "$2"' _ "$SRC" "$1" >"$CDIR/out" 2>&1 || RC=$?
  sed 's/^/  | /' "$CDIR/out" >>"$LOG"
}
check() { # description command...
  local what=$1; shift
  if "$@" >>"$LOG" 2>&1; then echo "  ok   $what" >>"$LOG"; else echo "  FAIL $what" >>"$LOG"; BAD+="$what; "; fi
}
eq() { [ "$1" = "$2" ] || { echo "    got '$1', want '$2'"; return 1; }; }
has() { grep -qE -- "$2" "$1" || { echo "    /$2/ not in ${1#"$WORK"/}"; return 1; }; }
hasnt() { ! grep -qE -- "$2" "$1" || { echo "    /$2/ found in ${1#"$WORK"/}"; return 1; }; }
out_has() { has "$CDIR/out" "$1"; }
out_hasnt() { hasnt "$CDIR/out" "$1"; }

FAILS=0 SKIPS=0 ROWS=()
run_case() { # id description function
  local on=1 p
  if [ ${#ONLY[@]} -gt 0 ]; then on=0; for p in "${ONLY[@]}"; do [[ $1 == "$p"* ]] && on=1; done; fi
  [ "$on" = 1 ] || return 0
  CASE=$1 CDIR=$WORK/cases/$1 BAD="" SKIP=""
  LOG=$CDIR/log
  mkdir -p "$CDIR"; : >"$LOG"
  reset_fake
  "$3"
  local r=PASS
  if [ -n "$BAD" ]; then r=FAIL FAILS=$((FAILS + 1))
  elif [ -n "$SKIP" ]; then r=SKIP SKIPS=$((SKIPS + 1)); fi
  echo "$r  $CASE${BAD:+  log: $LOG  (failed: ${BAD%; })}${SKIP:+  ($SKIP)}"
  ROWS+=("$(printf '%-24s %-4s %s' "$CASE" "$r" "$2")")
}

A=0000:01:00.0 B=0000:02:00.0 C=0000:21:00.0

# --- cases ---------------------------------------------------------------------------------------------------------
c01() {
  cfg "" ""
  local want="2206 GA102 default|2204 GA102 default|2684 AD102 opt-in|2704 AD103 opt-in|2786 AD104 opt-in|2803 AD106 opt-in
2882 AD107 opt-in|2482 GA104 opt-in|2414 GA103 opt-in|2504 GA106 opt-in|2584 GA107 opt-in|1e07 TU102 opt-in|1e87 TU104 opt-in
1f08 TU106 opt-in|2182 TU116 opt-in|1f82 TU117 opt-in|2b85 GB202 stock|2c02 GB203 stock|2f04 GB205 stock|2d04 GB206 stock
2d83 GB207 stock|20b0 GA100 datacenter|2330 GH100 datacenter|2901 GB100 datacenter|2e12 GB20B datacenter" t dev chip cls
  while read -r t; do
    read -r dev chip cls <<<"$t"
    lib "echo \$(chip_of_device $dev) \$(chip_class $chip)"
    check "10de:$dev is $chip ($cls)" eq "$(cat "$CDIR/out")" "$chip $cls"
  done < <(tr '|' '\n' <<<"$want")
  lib "chip_of_device 1d81"
  check "10de:1d81 (Volta) is no chip of the table" eq "$RC/$(cat "$CDIR/out")" "1/"
  local ids=${PCI_IDS:-}
  [ -n "$ids" ] || for ids in /usr/share/misc/pci.ids /usr/share/hwdata/pci.ids ""; do [ -z "$ids" ] || [ -r "$ids" ] && break; done
  if [ -z "$ids" ] || [ ! -r "$ids" ]; then SKIP="no pci.ids (PCI_IDS) for the table check"; return 0; fi
  # every 10de display entry from 1e00 on whose name starts with a chip name maps to that chip
  awk '/^10de / { v = 1; next } v && /^[0-9a-f]/ { exit } v && /^\t[0-9a-f]{4}  / { print substr($1, 1), substr($0, index($0, "  ") + 2) }' "$ids" |
    awk '$1 >= "1e00" && $2 ~ /^(TU|GA|AD|GH|GB)[0-9][0-9][0-9A-Z]/ && $0 !~ /Audio|USB|UCSI|Serial|NVSwitch|bridge|PCIe|Root/ { print $1, substr($2, 1, 5) }' >"$CDIR/pciids"
  lib 'while read -r d c; do x=$(chip_of_device "$d"); [ "$x" = "$c" ] || echo "MISMATCH 10de:$d pci.ids $c table ${x:-none}"; done <"'"$CDIR/pciids"'"; echo checked $(wc -l <"'"$CDIR/pciids"'")'
  check "chip table agrees with $ids" out_hasnt MISMATCH
  check "pci.ids entries checked" out_has '^checked [1-9][0-9]+$'
}
run_case 01-chip-table "device id -> chip -> class for every family; the table against pci.ids" c01

c02() {
  cfg "" ""
  card $A 2206 Ampere; card $B 2684 Ampere; card $C 2482 -
  mkdir -p "$FAKE/sys/bus/pci/devices/0000:22:00.1"; echo 0x10de >"$FAKE/sys/bus/pci/devices/0000:22:00.1/vendor"
  echo 0x040300 >"$FAKE/sys/bus/pci/devices/0000:22:00.1/class"; echo 0x1aef >"$FAKE/sys/bus/pci/devices/0000:22:00.1/device"
  lib "chip_check $A; echo \"\$C_CHIP|\$C_CLASS|\$C_IDS\""
  check "GA102 card, nvidia-smi agrees" eq "$(cat "$CDIR/out")" "GA102|verified|10de:2206/10de:146d"
  lib "chip_check $B; echo \"\$C_CHIP|\$C_CLASS|\$C_WHY\""
  check "device id AD102 but nvidia-smi Ampere: unknown" eq "$(cat "$CDIR/out")" "|unknown|device id 10de:2684 says AD102 (Ada Lovelace), nvidia-smi says Ampere"
  lib "chip_check $C; echo \"\$C_CHIP|\$C_CLASS\""
  check "card nvidia-smi does not list: by device id" eq "$(cat "$CDIR/out")" "GA104|opt-in"
  lib "chip_check 0000:22:00.1; echo \"\$C_CLASS|\$C_WHY\""
  check "audio function: not a GPU" eq "$(cat "$CDIR/out")" "unknown|0000:22:00.1 is not a display or 3D controller"
  lib "detect_gpus | tr '\n' ' '"
  check "detect_gpus: display functions only, in order" eq "$(cat "$CDIR/out")" "$A $B $C "
}
run_case 02-chip-check "chip_check: sysfs ids, nvidia-smi cross-check, non-GPU functions; detect_gpus" c02

c03() {
  cfg "" ""
  card $A 2206; card $B 2206; card $C 2482
  local pd="pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;pci=$C;RMForceStaticBar1=0;"
  v() { lib "pair_verdict '$1' $2 $3; echo \"\$V_STATE|\$V_TEXT\""; cat "$CDIR/out"; }
  check "RTX 3080 20GB pair: verified" eq "$(v "$pd" $A $B)" "verified|verified (on, GA102 + GA102: RTX 3080 20GB)"
  check "GA102 + GA104 without key: untested, only the GA104 card needs the key" eq "$(v "$pd" $A $C)" \
    "untested|untested (GA102 + GA104): run p2p-check.sh --integrity on a trial load (README, Opt-in), then enable with: p2p-enable.sh --yes $C"
  check "GA102 + GA104 with the key: opted in" eq "$(v "${pd}RMDynBar1P2PEnable=1;" $A $C)" \
    "opted-in|opted in (on, GA102 + GA104: RMDynBar1P2PEnable=1; not verified yet, please send a compatibility report)"
  check "GA102 pair, one card off: off" eq "$(v "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$B;RMForceStaticBar1=0;" $A $B)" \
    "off|off (GA102 + GA102: RMDynBar1P2PEnable is set and not 1 for $A)"
  check "last value wins: =0 then =1 is on" eq "$(v "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;" $A $B | cut -d'|' -f1)" verified
  check "static BAR1 on one card: untested, enable it (driver_option=on)" eq "$(v "pci=$A;RMForceStaticBar1=0;" $A $B)" \
    "untested|untested (GA102 + GA102): run p2p-check.sh --integrity on a trial load (README, Opt-in), then enable with: p2p-enable.sh --yes $B; static BAR1 on $B (no RMForceStaticBar1=0: geforce-bar1-resize sets it by default only for cards it enlarges through 0x610, dynamic BAR1 P2P needs it; p2p-enable.sh also sets driver_option=on for the card)"
  reset_fake; card $A 2204 Ampere 24576; card $B 2206 Ampere 10240
  check "RTX 3090 + RTX 3080 10GB: on by default, untested" eq "$(v "$pd" $A $B)" \
    "default|on by default, untested (GA102 + GA102: only the RTX 3080 20GB is verified): run p2p-check.sh --integrity once and please send a compatibility report"
  reset_fake; card $A 2206 - ; card $B 2206 -
  check "VRAM unknown (no driver): not counted as verified" eq "$(v "$pd" $A $B | cut -d'|' -f1)" default
  reset_fake; card $A 2206 Ampere 20480 256; card $B 2206
  check "BAR1 256 MiB < VRAM: not supported" eq "$(v "$pd" $A $B)" \
    "unsupported|not supported (BAR1 of $A is 256 MiB, smaller than its 20480 MiB of VRAM (geforce-bar1-resize enlarges it))"
  reset_fake; card $A 2206; card $B 2684 "Ada Lovelace" 24576
  check "Ampere + Ada: CUDA refuses" eq "$(v "${pd}RMDynBar1P2PEnable=1;" $A $B)" \
    "unsupported|not supported (GA102 + AD102: CUDA itself refuses peer access between Ampere and Ada Lovelace GPUs)"
  reset_fake; card $A 1e87 Turing 8192 8192; card $B 1e87 Turing 8192 8192
  check "Turing pair without key: untested, both cards" eq "$(v "$pd" $A $B | cut -d'|' -f1)" untested
  check "Turing pair: both named" eq "$(v "$pd" $A $B | grep -o 'p2p-enable.sh --yes.*')" "p2p-enable.sh --yes $A $B"
  reset_fake; card $A 2b85 Blackwell 32768 32768; card $B 2b85 Blackwell 32768 32768
  check "GB202 pair with RMForceStaticBar1=0: stock, with the static BAR1 note" eq "$(v "pci=$A;RMForceStaticBar1=0;" $A $B)" \
    "stock|stock (GB202 + GB202: NVIDIA's own driver offers BAR1 P2P on GB20x, this driver leaves the pair as stock; stock BAR1 P2P needs static BAR1, which RMForceStaticBar1=0 turns off for $A (driver_option=off for the card in geforce-bar1-resize))"
  check "GB202 pair without driver option: stock" eq "$(v "" $A $B)" "stock|stock (GB202 + GB202: NVIDIA's own driver offers BAR1 P2P on GB20x, this driver leaves the pair as stock)"
  reset_fake; card $A 2330 Hopper 81920 131072 0x030200; card $B 2330 Hopper 81920 131072 0x030200
  check "GH100: datacenter" eq "$(v "$pd" $A $B)" "unsupported|not supported (GH100 at $A is a datacenter chip, not a target of this driver patch)"
  reset_fake; card $A 1d81 Volta; card $B 2206
  check "unknown device id" eq "$(v "$pd" $A $B)" "unsupported|not supported (unknown chip: device id 10de:1d81 is in no known chip block)"
}
run_case 03-pair-rules "pair_verdict: verified, untested, opted in, off, static, BAR1, cross-architecture, stock, datacenter" c03

c04() {
  # the strings geforce-bar1-resize's tests (cases-p2p.sh) compare exactly, and the new P2P_ENABLE=1
  local s ok="pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
  ce() { cfg "" "$1"; lib "card_ok '$2' $3 ${4:-} && echo OK"; cat "$CDIR/out"; }
  check "'' accepts no key" eq "$(ce "" "$ok" $A)" OK
  check "'' accepts =1" eq "$(ce "" "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;" $A)" OK
  check "'' refuses =0 (exact text)" eq "$(ce "" "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;" $A)" "RMDynBar1P2PEnable=0 set for $A (P2P off) but P2P_ENABLE is not 0"
  check "0 wants =0 (exact text)" eq "$(ce 0 "$ok" $B)" "P2P_ENABLE=0 but no RMDynBar1P2PEnable=0 for $B"
  check "0 accepts =0" eq "$(ce 0 "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;" $A)" OK
  check "0: a later =1 wins" eq "$(ce 0 "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;RMDynBar1P2PEnable=1;" $A)" "RMDynBar1P2PEnable=1 for $A overrides RMDynBar1P2PEnable=0 (last value wins)"
  check "1 wants =1" eq "$(ce 1 "$ok" $A)" "P2P_ENABLE=1 but RMDynBar1P2PEnable is not set for $A, not 1"
  check "1 accepts =1" eq "$(ce 1 "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;" $A)" OK
  check "user RMForceStaticBar1=1 wins (exact text)" eq "$(ce "" "pci=$A;RMForceStaticBar1=0;RMForceStaticBar1=1;" $A)" "RMForceStaticBar1=1 for $A overrides RMForceStaticBar1=0 (last value wins)"
  check "static ignores the P2P key" eq "$(ce 1 "$ok" $A static)" OK
  check "no entry" eq "$(ce "" "$ok" $C)" "no per-device entry for $C"
  check "group ends at the next card" eq "$(ce 1 "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;" $A)" "P2P_ENABLE=1 but RMDynBar1P2PEnable is not set for $A, not 1"
  cfg "$A $B" 1; lib dwords
  check "dwords with P2P_ENABLE=1" eq "$(cat "$CDIR/out")" "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;"
  cfg "$A $B" 0; lib dwords
  check "dwords with P2P_ENABLE=0" eq "$(cat "$CDIR/out")" "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
  # geforce-bar1-resize's tests source the old location from bash -c, with P2P_CONFIG and $0 = "_"
  printf 'GPUS="%s"\nP2P_ENABLE=%s\nKVER=stand-in\n' "$A $B" "" >"$CDIR/p2p-config.sh"
  modprobe_line "$ok"
  # shellcheck disable=SC2016
  s=$(bash -c 'P2P_CONFIG=$1; . "$2/contrib/3080-20g/common.sh"; per_device_configured $3 && echo CONFIGURED-OK' _ "$CDIR/p2p-config.sh" "$SRC" "" 2>&1)
  check "old contrib/3080-20g/common.sh, as geforce-bar1-resize's tests source it" eq "$s" CONFIGURED-OK
  modprobe_line "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
  # shellcheck disable=SC2016
  s=$(bash -c 'P2P_CONFIG=$1; . "$2/contrib/3080-20g/common.sh"; per_device_configured $3 && echo CONFIGURED-OK' _ "$CDIR/p2p-config.sh" "$SRC" "" 2>&1)
  check "old location: hand opt-out refused with the same text" eq "$s" "RMDynBar1P2PEnable=0 set for $B (P2P off) but P2P_ENABLE is not 0"
}
run_case 04-card-ok-contract "card_ok texts geforce-bar1-resize's tests compare, P2P_ENABLE=1, dwords, old common.sh" c04

c05() {
  card $A 2206; card $B 2482; card $C 2b85 Blackwell 32768 32768
  modprobe_line "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
  touch "$FAKE/smi/off"
  cfg "" ""
  sh_ p2p-check.sh --pairs
  check "--pairs: status 0 as a normal user" eq "$RC" 0
  check "--pairs, driver not loaded: per-card options of the next load" out_has '^\(driver not loaded: per-card options of the next load\)$'
  check "--pairs, empty GPUS: every NVIDIA card" out_has "^$C 10de:2b85/10de:146d GB202 \(stock\)"
  check "GA102 + GA104: untested, enable the GA104" out_has "^$A <-> $B: untested \(GA102 \+ GA104\).*p2p-enable.sh --yes $B\$"
  check "GA104 + GB202: CUDA refuses" out_has "^$B <-> $C: not supported \(GA104 \+ GB202: CUDA itself refuses peer access between Ampere and Blackwell GPUs\)"
  rm "$FAKE/smi/off"; params "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;"
  cfg "$A $B" ""
  sh_ p2p-check.sh --pairs
  check "--pairs, driver loaded: the running driver's options" out_has '^\(per-card options of the running driver\)$'
  check "trial load with the key: opted in" out_has "^$A <-> $B: opted in \(on, GA102 \+ GA104"
  check "card line shows running and next-load key" out_has "^$B .*RMDynBar1P2PEnable running '1' next load ''$"
  sh_ p2p-check.sh --bogus
  check "unknown argument: status 2" eq "$RC" 2
}
run_case 05-check-pairs "p2p-check.sh --pairs: every card, verdicts, running vs next-load options" c05

full_setup() { # GPUS-cards with devices; per-device string; topo cell
  fake_build
  params "$1"
  modprobe_line "$1"
  topo "$2"
}
c06() {
  card $A 2206; card $B 2206
  cfg "$A $B" ""
  full_setup "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;" OK
  sh_ p2p-check.sh
  check "verified pair, topo OK: ALL PASS" out_has '^ALL PASS$'
  check "status 0" eq "$RC" 0
  check "BAR1 >= VRAM line" out_has "^PASS $A BAR1 32768 MiB >= VRAM 20480 MiB\$"
  check "topo per pair" out_has "^PASS topo -p2p r $A <-> $B: OK\$"
  topo NS
  sh_ p2p-check.sh
  check "verified pair, topo NS: FAIL" out_has "^FAIL topo -p2p w $A <-> $B: 'NS' although the pair is verified\$"
  reset_fake; card $A 2204 Ampere 24576; card $B 2204 Ampere 24576
  cfg "$A $B" ""
  full_setup "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;" OK
  sh_ p2p-check.sh
  check "RTX 3090 pair, topo OK: ALL PASS" out_has '^ALL PASS$'
  check "RTX 3090 pair: on by default, untested, run --integrity once" out_has "^$A <-> $B: on by default, untested \(GA102 \+ GA102: only the RTX 3080 20GB is verified\): run p2p-check.sh --integrity once"
  reset_fake; card $A 2482; card $B 2482
  cfg "$A $B" ""
  full_setup "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;" NS
  sh_ p2p-check.sh
  check "untested GA104 pair, topo NS: ALL PASS" out_has '^ALL PASS$'
  check "untested shown with what to do" out_has "^$A <-> $B: untested \(GA104 \+ GA104\)"
  topo OK
  sh_ p2p-check.sh
  check "untested pair but topo OK: FAIL" out_has "^FAIL topo -p2p r $A <-> $B: OK although the pair is untested\$"
  reset_fake; card $A 2206; card $B 2b85 Blackwell 32768 32768
  cfg "$A $B" ""
  full_setup "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;" NS
  sh_ p2p-check.sh
  check "Blackwell card in GPUS: FAIL, remove it" out_has "^FAIL $B: GB202 \(stock\) is not a card for this driver's P2P; remove it from GPUS\$"
  reset_fake; card $A 2206; card $B 2206 Ampere 20480 16384
  cfg "$A $B" ""
  full_setup "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;" NS
  sh_ p2p-check.sh
  check "BAR1 below VRAM: FAIL" out_has "^FAIL $B BAR1 Total '16384' MiB is not at least its VRAM '20480' MiB\$"
}
run_case 06-check "p2p-check.sh: BAR1 >= VRAM, verdicts against nvidia-smi topo per pair, cards not for this driver" c06

# standin_integrity: the integrity test stand-in in place of contrib/integrity/p2p-integrity. Status from
# $FAKE/integrity-rc, cases from $FAKE/integrity-cases (default 264); $FAKE/integrity-xid adds an Xid line of the
# pair, -hang hangs, -other adds a refusal and an Xid of a third card, -own a refusal naming a card of the pair; the
# CUDA_VISIBLE_DEVICES it got goes to $FAKE/visible. Arguments: --pair A B --max-mib N ...
standin_integrity() {
  mkdir -p "$SRC/contrib/integrity"
  cat >"$SRC/contrib/integrity/p2p-integrity" <<'EOF'
#!/bin/bash
echo "p2p-integrity stand-in $*"
[ ! -e "$FAKE/integrity-xid" ] || echo "NVRM: Xid (PCI:0000:01:00): 31, fake" >>"$FAKE/dmesg"
[ ! -e "$FAKE/integrity-hang" ] || sleep 600
echo "${CUDA_VISIBLE_DEVICES-unset}" >"$FAKE/visible"
# a third card the driver refuses to pair with logs its own refusal and an Xid of its own
[ ! -e "$FAKE/integrity-other" ] || printf '%s\n' "NVRM: DynBar1P2P: GPU 0000:21:00: not GA102 and RMDynBar1P2PEnable=1 not set (dynamic route not armed); BAR1 P2P not advertised for pair GPU0 <-> GPU2" \
  "NVRM: Xid (PCI:0000:21:00): 79, fake" >>"$FAKE/dmesg"
[ ! -e "$FAKE/integrity-own" ] || echo "NVRM: DynBar1P2P: GPU 0000:01:00: fake refusal; BAR1 P2P not advertised for pair GPU0 <-> GPU1" >>"$FAKE/dmesg"
rc=$(cat "$FAKE/integrity-rc" 2>/dev/null || echo 0)
case $rc in 0) r=PASS ;; 3) r=NO_P2P ;; 4) echo "  TIMEOUT: push did not finish"; r=FAIL ;; *) r=FAIL ;; esac
echo "RESULT $r $2 $3 max-mib $5 cases $(cat "$FAKE/integrity-cases" 2>/dev/null || echo 264) transfers 8 copied 1.0 GiB"
exit "$rc"
EOF
  chmod 755 "$SRC/contrib/integrity/p2p-integrity"
  touch -d '+1 hour' "$SRC/contrib/integrity/p2p-integrity"
}
c07() {
  card $A 2482; card $B 2482
  cfg "$A $B" 1
  full_setup "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;" OK
  modprobe_line "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
  standin_integrity
  sh_ p2p-check.sh --integrity --max-mib 64
  check "opted-in pair, integrity PASS: status 0" eq "$RC" 0
  check "integrity line with size and cases" out_has "^PASS integrity $A <-> $B \(max-mib 64, 264 cases\)\$"
  check "the test got the pair and the size" out_has "^  p2p-integrity stand-in --pair $A $B --max-mib 64"
  check "PASS recorded with ids, size and cases" has "$FAKE/var/lib/geforce-dynbar1-p2p/integrity-pass" " PASS $A 10de:2482/10de:146d $B 10de:2482/10de:146d nvidia SRC-nvidia .*max-mib 64 cases 264\$"
  check "a short run is named as not counting for p2p-enable" out_has "^note: a run below --max-mib 4096 \(264 cases\) does not count for p2p-enable.sh\$"
  local rep; rep=$(sed -n 's/^This output is in \(.*\)\. Please attach.*/\1/p' "$CDIR/out")
  check "report written" has "${rep:-/nonexistent}" "^PASS integrity $A <-> $B "
  check "report has the system section" has "${rep:-/nonexistent}" '^== system'
  check "report: what to send" out_has 'Please attach it to a compatibility report: https://github.com/noon-at-cgn/geforce-dynbar1-p2p/issues/new\?template=compatibility-report.md'
  check "next step: enable for the boot" out_has "^To keep P2P on for these cards from the next boot \(.*\): sudo .*/p2p-enable.sh --yes $A $B\$"
  echo 1 >"$FAKE/integrity-rc"
  sh_ p2p-check.sh --integrity
  check "integrity FAIL counted" out_has "^FAIL integrity $A <-> $B \(p2p-integrity exit status 1\)\$"
  check "status 1" eq "$RC" 1
  echo 0 >"$FAKE/integrity-rc"; touch "$FAKE/integrity-xid"
  sh_ p2p-check.sh --integrity
  check "clean copies but a new Xid: FAIL" out_has "^FAIL integrity $A <-> $B: copies clean, but the kernel log has new events"
  rm "$FAKE/integrity-xid"; : >"$FAKE/dmesg"
  echo 3 >"$FAKE/integrity-rc"
  cfg "$A $B" ""
  full_setup "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;" NS
  sh_ p2p-check.sh --integrity
  check "untested pair, no peer access: NOT RUN with the trial-load command" out_has "^NOT RUN $A <-> $B: no peer access \(the pair is untested\)\. Trial load .*sudo env P2P_ENABLE=1 .*/p2p-load.sh --yes"
  check "  nothing tested: FAIL, not ALL PASS" out_has "^FAIL integrity: no pair was tested \(0 skipped, 1 not run\)"
  check "  no ALL PASS line" eq "$(grep -c '^ALL PASS$' "$CDIR/out")" 0
  check "  status 1" eq "$RC" 1
  # an exit status 0 without cases is no PASS
  cfg "$A $B" 1
  full_setup "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;" OK
  echo 0 >"$FAKE/integrity-rc"; echo 0 >"$FAKE/integrity-cases"; : >"$FAKE/var/lib/geforce-dynbar1-p2p/integrity-pass"
  sh_ p2p-check.sh --integrity
  check "status 0 with cases 0: FAIL" out_has "^FAIL integrity $A <-> $B: exit status 0 but no 'RESULT PASS \.\.\. cases N' line with N > 0\$"
  check "status 0 with cases 0: no PASS recorded" eq "$(grep -c PASS "$FAKE/var/lib/geforce-dynbar1-p2p/integrity-pass")" 0
  # the test's own timeout (status 4), and a hang that only the outer timeout ends
  rm -f "$FAKE/integrity-cases"; echo 4 >"$FAKE/integrity-rc"
  sh_ p2p-check.sh --integrity
  check "status 4 from the test: FAIL timed out" out_has "^FAIL integrity $A <-> $B: timed out \(hung peer transfer\?; limits [0-9]+ s for the run, 184 s per transfer\)\$"
  check "the limits, scaled with --max-mib, are passed to the test" out_has "^  p2p-integrity stand-in --pair $A $B --max-mib 4096 --timeout 3248 --op-timeout 184\$"
  sh_ p2p-check.sh --integrity --max-mib 65536
  check "--max-mib 65536: 120 + 65536/64 s per transfer" out_has "^  p2p-integrity stand-in --pair $A $B --max-mib 65536 --timeout 33968 --op-timeout 1144\$"
  echo 0 >"$FAKE/integrity-rc"; touch "$FAKE/integrity-hang"
  local t0=$SECONDS
  INTEGRITY_TIMEOUT=1 sh_ p2p-check.sh --integrity
  check "a hang ends in a FAIL line within the limit" out_has "^FAIL integrity $A <-> $B: timed out"
  check "... after about 1 s + 5 s grace, not 600 s" test $((SECONDS - t0)) -lt 30
  check "... and no PASS recorded" eq "$(grep -c PASS "$FAKE/var/lib/geforce-dynbar1-p2p/integrity-pass")" 0
  # after a timeout no further pair runs (three cards, three pairs; only the first one is tried)
  card $C 2482
  cfg "$A $B $C" 1
  full_setup "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$C;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;" OK
  INTEGRITY_TIMEOUT=1 sh_ p2p-check.sh --integrity
  check "one pair tried, then STOPPED" eq "$(grep -c '^-- ' "$CDIR/out")/$(grep -c '^STOPPED after the timeout' "$CDIR/out")" "1/1"
  cfg "$A $B" 1
  full_setup "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;" OK
  rm -f "$FAKE/integrity-hang"
  # another nvidia build loaded: the check FAILs and no PASS is recorded
  echo OTHER-BUILD >"$FAKE/sys/module/nvidia/srcversion"; : >"$FAKE/var/lib/geforce-dynbar1-p2p/integrity-pass"
  sh_ p2p-check.sh --integrity
  check "another nvidia build loaded: check FAILs" out_has '^FAIL nvidia loaded'
  check "  no PASS recorded for p2p-enable" eq "$(grep -c PASS "$FAKE/var/lib/geforce-dynbar1-p2p/integrity-pass")" 0
  check "  and says so" out_has '^note: PASS not recorded for p2p-enable.sh: the check above has [0-9]+ FAIL line'
  echo SRC-nvidia >"$FAKE/sys/module/nvidia/srcversion"
  sh_ p2p-check.sh --integrity
  check "PASS names the loaded build and version" has "$FAKE/var/lib/geforce-dynbar1-p2p/integrity-pass" " nvidia SRC-nvidia version 615.71.09 max-mib 4096 cases 264\$"
  check "  counts the tested pair" out_has '^integrity: 1 pair\(s\) tested, 0 skipped, 0 not run'
  # the only pair is unsupported (Ampere + Ada: CUDA refuses): skipped, so nothing is tested and that is no ALL PASS
  reset_fake; card $A 2482; card $B 2684 "Ada Lovelace" 24576
  cfg "$A $B" 1
  full_setup "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;" OK
  sh_ p2p-check.sh --integrity
  check "unsupported pair: SKIP" out_has "^SKIP $A <-> $B: not tested \(the pair is unsupported\)\$"
  check "  the test did not run" eq "$(grep -c 'p2p-integrity stand-in' "$CDIR/out")" 0
  check "  nothing tested: FAIL" out_has "^FAIL integrity: no pair was tested \(1 skipped, 0 not run\)"
  check "  no ALL PASS line" eq "$(grep -c '^ALL PASS$' "$CDIR/out")" 0
  check "  status 1" eq "$RC" 1
}

c17() {
  # a third, unpairable card in the machine: the test sees only the pair, and the other card's refusal and Xid
  # lines do not fail it; a line that names a card of the pair still does
  card $A 2482; card $B 2482; card $C 2206
  cfg "$A $B" 1
  full_setup "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$C;RMForceStaticBar1=0;" OK
  standin_integrity
  touch "$FAKE/integrity-other"
  sh_ p2p-check.sh --integrity
  check "third card's refusal and Xid lines: the pair still PASSes" out_has "^PASS integrity $A <-> $B "
  check "CUDA sees only the pair (by UUID)" eq "$(cat "$FAKE/visible")" "GPU-00000000-0000-0000-0000-000000000000,GPU-00000001-0000-0000-0000-000000000001"
  check "  said without the UUIDs" out_has "CUDA sees only these two cards\$"
  check "no UUID in the output or the report" out_hasnt 'GPU-0000000'
  rm "$FAKE/integrity-other"; touch "$FAKE/integrity-own"
  sh_ p2p-check.sh --integrity
  check "a refusal line naming a card of the pair: FAIL" out_has "^FAIL integrity $A <-> $B: copies clean, but the kernel log has new events"
}
run_case 07-check-integrity "p2p-check.sh --integrity: PASS record, report, FAIL, kernel-log events, NOT RUN" c07
run_case 17-integrity-third-card "--integrity with a third, unpairable GPU" c17

gbr_conf() { printf '%s\n' "$@" >"$FAKE/etc/geforce-bar1-resize.conf"; }
# pass_rec A B [max-mib] [cases] [srcversion]: an integrity PASS record of the pair (default: the full size, this build)
pass_rec() { mkdir -p "$FAKE/var/lib/geforce-dynbar1-p2p"; echo "2026-11-01T00:00:00Z PASS $1 10de:2482/10de:146d $2 x nvidia ${5:-SRC-nvidia} version 615.71.09 max-mib ${3:-4096} cases ${4:-264}" >>"$FAKE/var/lib/geforce-dynbar1-p2p/integrity-pass"; }
c08() {
  card $A 2482; card $B 2482; card $C 2206
  fake_build
  printf '%s 0x610\n' $A $B $C >"$FAKE/gbr-cards"
  cfg "" ""
  gbr_conf 'CARDS=auto' 'declare -A CARD=(' '  [10de:2482]="size=32G"' ')'
  geforce-bar1-resize driver-option --write
  sh_ p2p-enable.sh --yes $A
  check "no integrity PASS: refused" out_has "^ABORT: $A \(GA104, 10de:2482/10de:146d\): no full --integrity PASS recorded"
  check "config untouched" eq "$(grep -c RMDynBar1P2PEnable "$FAKE/etc/geforce-bar1-resize.conf")" 0
  pass_rec $A $B 64 264
  pass_rec $A $B 4096 10
  pass_rec $A $B 4096 264 OTHER-BUILD
  sh_ p2p-enable.sh --yes $A
  check "a PASS of a short run (--max-mib 64, too few cases) or of another nvidia build does not count" out_has "^ABORT: $A .*no full --integrity PASS recorded"
  check "names the build that boots" out_has "^build that boots: .*/out/nvidia.ko \(srcversion SRC-nvidia\)"
  pass_rec $A $B
  sh_ p2p-enable.sh --dry-run $A
  check "dry run: plan shows the address entry copied from vendor:device" out_has "^\+  \[$A\]=\"ids=10de:2482/10de:146d size=32G keys=RMDynBar1P2PEnable=1;\"\$"
  check "dry run: nothing written" eq "$(grep -c RMDynBar1P2PEnable "$FAKE/etc/geforce-bar1-resize.conf")" 0
  sh_ p2p-enable.sh --yes $A
  check "enable: status 0" eq "$RC" 0
  check "entry in the CARD block" has "$FAKE/etc/geforce-bar1-resize.conf" "^  \[$A\]=\"ids=10de:2482/10de:146d size=32G keys=RMDynBar1P2PEnable=1;\"\$"
  check "geforce-bar1-resize driver-option --write ran" has "$FAKE/calls" '^geforce-bar1-resize driver-option --write$'
  check "the option line: key for $A only" has "$FAKE/modprobe-c" "\"pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;pci=$C;RMForceStaticBar1=0;\""
  check "backup" eq "$(find "$FAKE/var/backups/geforce-dynbar1-p2p" -name geforce-bar1-resize.conf | wc -l)" 1
  check "config still valid bash" bash -n "$FAKE/etc/geforce-bar1-resize.conf"
  gbr_conf 'declare -A CARD=(' ')' "CARD[$A]=\"size=64G keys=RMFoo=3;RMDynBar1P2PEnable=0;\""
  sh_ p2p-enable.sh --yes $A
  check "one-line address entry replaced in place, other words and keys kept, key last" has "$FAKE/etc/geforce-bar1-resize.conf" \
    "^CARD\[$A\]=\"ids=10de:2482/10de:146d size=64G keys=RMFoo=3;RMDynBar1P2PEnable=1;\"\$"
  check "one entry for $A" eq "$(grep -c "$A" "$FAKE/etc/geforce-bar1-resize.conf")" 1
  sh_ p2p-enable.sh --yes --undo $A
  check "undo: key removed, rest kept" has "$FAKE/etc/geforce-bar1-resize.conf" "^CARD\[$A\]=\"ids=10de:2482/10de:146d size=64G keys=RMFoo=3;\"\$"
  check "undo: option line without the key" has "$FAKE/modprobe-c" "\"pci=$A;RMForceStaticBar1=0;RMFoo=3;pci=$B"
  gbr_conf 'CARDS=auto'
  sh_ p2p-enable.sh --yes --skip-integrity $B
  check "no CARD block: appended" has "$FAKE/etc/geforce-bar1-resize.conf" "^CARD\[$B\]=\"ids=10de:2482/10de:146d keys=RMDynBar1P2PEnable=1;\"\$"
  sh_ p2p-enable.sh --yes --undo $B
  check "undo of an entry with only the key: entry removed" eq "$(grep -c "$B" "$FAKE/etc/geforce-bar1-resize.conf")" 0
  gbr_conf 'declare -A CARD=(' "  [$A]=\"size=32G" "    keys=RMDynBar1P2PEnable=0;\"" ')'
  sh_ p2p-enable.sh --yes $A
  check "multi-line entry: refused" out_has "^ABORT: CARD\[$A\] in .* spans several lines"
  gbr_conf 'declare -A CARD=(' "  [$A]=\"ids=10de:1234\"" ')'
  sh_ p2p-enable.sh --dry-run $A
  check "address entry for another card (ids differ) is not the card's entry" out_has "^$A: GA104 \(10de:2482/10de:146d\); no CARD\[\] entry yet\$"
  sh_ p2p-enable.sh --yes $C
  check "GA102 with RMForceStaticBar1=0: nothing to do" out_has "^$C: GA102, P2P on by default and RMForceStaticBar1=0 already set; nothing to do\$"
  card 0000:05:00.0 2b85 Blackwell 32768 32768
  sh_ p2p-enable.sh --yes --skip-integrity 0000:05:00.0
  check "GB202: refused" out_has "^ABORT: 0000:05:00.0: GB202 is GeForce Blackwell"
  sh_ p2p-enable.sh $A
  check "no --yes: refused" eq "$RC" 2
  modprobe_line "pci=$B;RMForceStaticBar1=0;"
  sh_ p2p-enable.sh --yes --skip-integrity $A
  check "card without RMForceStaticBar1=0: driver_option=on added" has "$FAKE/etc/geforce-bar1-resize.conf" "^  \[$A\]=\"ids=10de:2482/10de:146d driver_option=on keys=RMDynBar1P2PEnable=1;\"\$"
  check "card without RMForceStaticBar1=0: status 0" eq "$RC" 0
  # geforce-bar1-resize's default (auto): a resize-only card keeps static BAR1 until driver_option=on
  printf '%s resize\n' $A $B >"$FAKE/gbr-cards"; printf '%s 0x610\n' $C >>"$FAKE/gbr-cards"
  gbr_conf 'declare -A CARD=(' ')'
  geforce-bar1-resize driver-option --write
  check "resize-only cards: no RMForceStaticBar1=0 by default" has "$FAKE/modprobe-c" "\"pci=$C;RMForceStaticBar1=0;\""
  sh_ p2p-enable.sh --yes $A
  check "resize-only opt-in card: driver_option=on and the key" has "$FAKE/etc/geforce-bar1-resize.conf" "^  \[$A\]=\"ids=10de:2482/10de:146d driver_option=on keys=RMDynBar1P2PEnable=1;\"\$"
  check "resize-only opt-in card: RMForceStaticBar1=0 and the key at the next load" has "$FAKE/modprobe-c" "\"pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$C"
  check "resize-only opt-in card: verified as applied" out_has "^$A: RMForceStaticBar1=0 at the next load of nvidia\$"
  card 0000:06:00.0 2204 Ampere 24576; echo "0000:06:00.0 resize" >>"$FAKE/gbr-cards"
  sh_ p2p-enable.sh --yes --skip-integrity 0000:06:00.0
  check "resize-only GA102: driver_option=on, no key" has "$FAKE/etc/geforce-bar1-resize.conf" "^  \[0000:06:00.0\]=\"ids=10de:2204/10de:146d driver_option=on\"\$"
  check "resize-only GA102: RMForceStaticBar1=0 at the next load" has "$FAKE/modprobe-c" "pci=0000:06:00.0;RMForceStaticBar1=0;\""
  card 0000:09:00.0 2684 "Ada Lovelace" 24576; echo "0000:09:00.0 large" >>"$FAKE/gbr-cards"
  sh_ p2p-enable.sh --yes --skip-integrity 0000:09:00.0
  check "stock-ReBAR Ada (firmware BAR1 already large): driver_option=on and the key applied" has "$FAKE/modprobe-c" \
    "pci=0000:09:00.0;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;\""
  card 0000:07:00.0 2482
  cp "$FAKE/etc/geforce-bar1-resize.conf" "$CDIR/before.conf"; cp "$FAKE/modprobe-c" "$CDIR/before.opt"
  local w0; w0=$(grep -c -- 'driver-option --write' "$FAKE/calls")
  sh_ p2p-enable.sh --yes --skip-integrity 0000:07:00.0
  check "card outside geforce-bar1-resize's scope: not applied" out_has "^ABORT: not applied: geforce-bar1-resize would not write this"
  check "  seen in the preview" out_has "^0000:07:00.0: no RMForceStaticBar1=0 in the preview"
  check "  config unchanged" cmp "$CDIR/before.conf" "$FAKE/etc/geforce-bar1-resize.conf"
  check "  option file unchanged" cmp "$CDIR/before.opt" "$FAKE/modprobe-c"
  check "  driver-option --write did not run" eq "$(grep -c -- 'driver-option --write' "$FAKE/calls")" "$w0"
  # --write fails after the config was written: both files go back
  touch "$FAKE/gbr-write-fails"
  sh_ p2p-enable.sh --yes --skip-integrity $B
  check "failed --write: rolled back" out_has "^ABORT: driver-option --write failed; rolled back: "
  check "  config as before" cmp "$CDIR/before.conf" "$FAKE/etc/geforce-bar1-resize.conf"
  check "  option file as before" cmp "$CDIR/before.opt" "$FAKE/modprobe-c"
  # a rollback whose copy is gone says ROLLBACK FAILED instead of 'rolled back'
  touch "$FAKE/gbr-eat-backup"
  sh_ p2p-enable.sh --yes --skip-integrity $B
  check "failed restore reported" out_has "^ABORT: driver-option --write failed; ROLLBACK FAILED for: .*geforce-bar1-resize.conf \(copy: "
  check "  not reported as rolled back" out_hasnt "rolled back:"
  cp "$CDIR/before.conf" "$FAKE/etc/geforce-bar1-resize.conf"; cp "$CDIR/before.opt" "$FAKE/modprobe-c"
  rm "$FAKE/gbr-write-fails" "$FAKE/gbr-eat-backup"
  card 0000:08:00.0 2482 Ampere 20480 256
  sh_ p2p-enable.sh --yes --skip-integrity 0000:08:00.0
  check "BAR1 below VRAM: refused" out_has "^ABORT: 0000:08:00.0: BAR1 256 MiB is smaller than its 20480 MiB of VRAM"
}
run_case 08-enable "p2p-enable.sh: integrity gate, keys= through geforce-bar1-resize's config, in place, undo, refusals" c08

c12() {
  # --undo never removes a user's RMDynBar1P2PEnable=0, nor a =1 it did not set
  cfg "" ""
  card $C 2206; card $A 2482
  printf '%s 0x610\n' $C $A >"$FAKE/gbr-cards"
  gbr_conf 'declare -A CARD=(' "  [$C]=\"keys=RMDynBar1P2PEnable=0;\"" "  [$A]=\"keys=RMDynBar1P2PEnable=1;\"" ')'
  geforce-bar1-resize driver-option --write
  cp "$FAKE/etc/geforce-bar1-resize.conf" "$CDIR/before.conf"
  sh_ p2p-enable.sh --yes --undo $C
  check "undo on GA102 keeps the user's opt-out RMDynBar1P2PEnable=0" has "$FAKE/etc/geforce-bar1-resize.conf" "\[$C\]=\"keys=RMDynBar1P2PEnable=0;\""
  check "  option line still has =0" has "$FAKE/modprobe-c" "pci=$C;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
  check "  and says there is nothing to undo" out_has "^$C: no RMDynBar1P2PEnable=1 in its entry, nothing to undo\$"
  sh_ p2p-enable.sh --yes --undo $A
  check "a =1 not set by p2p-enable.sh: refused" out_has "^ABORT: $A: RMDynBar1P2PEnable=1 in CARD\[$A\] was not set by p2p-enable.sh"
  check "  config unchanged" cmp "$CDIR/before.conf" "$FAKE/etc/geforce-bar1-resize.conf"
  sh_ p2p-enable.sh --yes --skip-integrity $A
  check "enable records the card" has "$FAKE/var/lib/geforce-dynbar1-p2p/enabled" "^$A 10de:2482/10de:146d\$"
  sh_ p2p-enable.sh --yes --undo $A
  check "then --undo removes its =1" bash -c '! grep -q "pci=$1;RMForceStaticBar1=0;RMDynBar1P2PEnable=1" "$2"' _ $A "$FAKE/modprobe-c"
  check "  and forgets the card" bash -c '! grep -q "^$1 " "$2"' _ $A "$FAKE/var/lib/geforce-dynbar1-p2p/enabled"
}
run_case 12-enable-undo-own-key "p2p-enable.sh --undo: only the RMDynBar1P2PEnable=1 it set" c12

c13() {
  # --undo with the key in a vendor:device entry refuses clearly instead of "nothing to change"
  cfg "" ""
  card $A 2482; card $B 2482
  printf '%s 0x610\n' $A $B >"$FAKE/gbr-cards"
  gbr_conf 'declare -A CARD=(' '  [10de:2482]="keys=RMDynBar1P2PEnable=1;"' ')'
  geforce-bar1-resize driver-option --write
  cp "$FAKE/etc/geforce-bar1-resize.conf" "$CDIR/before.conf"
  sh_ p2p-enable.sh --yes --undo $A
  check "non-zero status" bash -c '[ "$1" != 0 ]' _ "$RC"
  check "names the shared entry" out_has "^ABORT: $A: RMDynBar1P2PEnable=1 comes from the shared entry CARD\[10de:2482\] in "
  check "config unchanged" cmp "$CDIR/before.conf" "$FAKE/etc/geforce-bar1-resize.conf"
}
run_case 13-enable-undo-shared "p2p-enable.sh --undo with the key in a vendor:device entry" c13

c14() {
  # the old contrib/3080-20g/config.sh documents P2P_ENABLE=1 as the default; it still works so
  card $A 2206; card $B 2206
  printf 'GPUS="%s"\nKVER=stand-in\nOUT=%s\nP2P_ENABLE=1\n' "$A $B" "$WORK/out" >"$SRC/contrib/3080-20g/config.sh"
  full_setup "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;" OK
  echo "\$ contrib/3080-20g/p2p-check.sh (old config P2P_ENABLE=1)" >>"$LOG"
  "$SRC/contrib/3080-20g/p2p-check.sh" >"$CDIR/out" 2>&1; RC=$?
  sed 's/^/  | /' "$CDIR/out" >>"$LOG"
  check "old config.sh with P2P_ENABLE=1 (its documented default): boot install ALL PASS" out_has '^ALL PASS$'
  check "  with a note on the old meaning" out_has '^note: P2P_ENABLE=1 from contrib/3080-20g/config.sh is the driver default there'
  check "the old config.sh in the repository documents it" has "$PUB/contrib/3080-20g/config.sh" 'with this file the'
  cp "$PUB/contrib/3080-20g/config.sh" "$SRC/contrib/3080-20g/config.sh"
  cfg "$A $B" 1
  sh_ p2p-check.sh
  check "contrib/config.sh with P2P_ENABLE=1 keeps the new meaning" out_has "^FAIL P2P_ENABLE=1 but RMDynBar1P2PEnable is not set for $A, not 1\$"
  echo "\$ P2P_CONFIG=/nonexistent p2p-check.sh" >>"$LOG"
  P2P_CONFIG=$CDIR/missing.sh "$SRC/contrib/p2p-check.sh" >"$CDIR/out" 2>&1; RC=$?
  check "a missing P2P_CONFIG file is named" out_has "^ABORT: cannot read $CDIR/missing.sh\$"
}
run_case 14-old-config-p2p-enable-1 "contrib/3080-20g/config.sh P2P_ENABLE=1 keeps its documented meaning" c14

c15() {
  # malformed addresses are refused before anything is written
  cfg "" ""
  card $A 2482
  printf '%s 0x610\n' $A >"$FAKE/gbr-cards"
  gbr_conf 'declare -A CARD=(' ')'
  geforce-bar1-resize driver-option --write
  cp "$FAKE/etc/geforce-bar1-resize.conf" "$CDIR/before.conf"
  local bad
  for bad in "$A/" "$A/../$A" "0000:1:00.0" "01:00.0" "0000:01:00.0;x" "0000:01:00.8"; do
    sh_ p2p-enable.sh --yes --skip-integrity "$bad"
    check "p2p-enable.sh refuses '$bad'" out_has "^ABORT: '.*' is not a full PCI address like 0000:01:00.0"
    check "  config unchanged" cmp "$CDIR/before.conf" "$FAKE/etc/geforce-bar1-resize.conf"
  done
  fake_build
  cfg "$A/ $B" ""
  sh_ p2p-load.sh --dry-run
  check "GPUS with a malformed address: p2p-load.sh refuses" out_has "^ABORT: GPUS: '$A/' is not a full PCI address"
  sh_ p2p-check.sh --pairs
  check "  p2p-check.sh refuses too" out_has "^ABORT: GPUS: '$A/' is not a full PCI address"
}
run_case 15-address-validation "malformed card addresses refused" c15

c16() {
  # enabling a GA102 card that was turned off by hand is not "nothing to do"
  cfg "" ""
  card $C 2206
  printf '%s 0x610\n' $C >"$FAKE/gbr-cards"
  gbr_conf 'declare -A CARD=(' "  [$C]=\"keys=RMDynBar1P2PEnable=0;\"" ')'
  geforce-bar1-resize driver-option --write
  sh_ p2p-enable.sh --yes --skip-integrity $C
  check "GA102 with RMDynBar1P2PEnable=0: not reported as 'nothing to do'" out_hasnt 'nothing to do'
  check "  says it is off" out_has "^$C: GA102 is turned off \(RMDynBar1P2PEnable=0 at the next load\)"
  check "  and turns it on (the =0 is gone)" bash -c '! grep -q "RMDynBar1P2PEnable=0" "$1"' _ "$FAKE/modprobe-c"
  # the key was added by hand to the option file, not through keys=: say so, change nothing
  gbr_conf 'declare -A CARD=(' ')'
  cp "$FAKE/etc/geforce-bar1-resize.conf" "$CDIR/before.conf"
  modprobe_line "pci=$C;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
  sh_ p2p-enable.sh --yes --skip-integrity $C
  check "=0 added by hand to the option file: named, not 'outside its scope'" out_has "^ABORT: $C: RMDynBar1P2PEnable=0 was added by hand to .* remove it there"
  check "  config unchanged" cmp "$CDIR/before.conf" "$FAKE/etc/geforce-bar1-resize.conf"
  card $A 2482; modprobe_line "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;"
  sh_ p2p-enable.sh --yes --undo $A
  check "--undo of a =1 added by hand: named, non-zero status" out_has "^ABORT: $A: RMDynBar1P2PEnable=1 was added by hand to .* remove it there"
}
run_case 16-enable-ga102-off "p2p-enable.sh on a GA102 card turned off by hand" c16

c18() {
  # the preview checks geforce-bar1-resize's own line; a foreign per-device line is named as such
  cfg "" ""
  card $A 2482
  printf '%s 0x610\n' $A >"$FAKE/gbr-cards"
  gbr_conf 'declare -A CARD=(' ')'
  geforce-bar1-resize driver-option --write
  cp "$FAKE/etc/geforce-bar1-resize.conf" "$CDIR/before.conf"
  echo "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMDynBar1P2PEnable=0;\"" >"$FAKE/gbr-foreign"
  sh_ p2p-enable.sh --yes --skip-integrity $A
  check "foreign line: named, not 'card outside its scope'" out_has "^ABORT: not applied: NVreg_RegistryDwordsPerDevice line in /etc/modprobe.d/other.conf: .*--write stops on it"
  check "  config unchanged" cmp "$CDIR/before.conf" "$FAKE/etc/geforce-bar1-resize.conf"
  rm "$FAKE/gbr-foreign"
  sh_ p2p-enable.sh --dry-run --skip-integrity $A
  check "without it: the preview reads the 'options nvidia' line" out_has "^$A: RMDynBar1P2PEnable 1 in the preview\$"
}
run_case 18-enable-preview-foreign "p2p-enable.sh preview with a foreign per-device line" c18

c09() {
  card $A 2482; card $B 2482
  fake_build; params "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
  cfg "$A $B" 1
  sh_ p2p-load.sh --dry-run
  check "plan: insmod with RMDynBar1P2PEnable=1 per card" out_has "^\+ insmod .*/nvidia.ko NVreg_RegistryDwordsPerDevice=pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1; NVreg_EnableResizableBar=0\$"
  check "chips listed" out_has "^$A: GA104 \(10de:2482/10de:146d\), opt-in"
  check "dry run: nothing loaded" eq "$(grep -c insmod "$FAKE/calls")" 0
  card $C 2b85 Blackwell 32768 32768
  cfg "$A $C" ""
  sh_ p2p-load.sh --dry-run
  check "Blackwell card in GPUS: refused" out_has "^ABORT: $C: GB202 is GeForce Blackwell"
  cfg "$A $B" 2
  sh_ p2p-load.sh --dry-run
  check "P2P_ENABLE=2: refused" out_has '^ABORT: P2P_ENABLE must be empty, 0 or 1$'
}
run_case 09-load-plan "p2p-load.sh --dry-run: per-card key for the trial load; chip refusals" c09

# stock_loaded PER-DEVICE-STRING: the stock 615.71.09 stack runs with that string (also the one modprobe reads); the
# build is in $WORK/out
stock_loaded() {
  local m
  fake_build; params "$1"; modprobe_line "$1"
  for m in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do echo "STOCK-${m//_/-}" >"$FAKE/sys/module/$m/srcversion"; done
}
PD2="pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
c19() {
  card $A 2206; card $B 2206; stock_loaded "$PD2"; cfg "$A $B" ""
  rm -rf "$FAKE/lib/firmware"
  sh_ p2p-load.sh --yes
  check "no GSP firmware: p2p-load.sh refuses, naming both files" out_has "^ABORT: GSP firmware not found: nvidia/615.71.09/gsp_ga10x.bin nvidia/615.71.09/ucodes_ga10x.bin\$"
  check "  says where it looked" out_has "^Looked in: .*/lib/firmware\$"
  check "  says where to get it" out_has "^NVIDIA-Linux-x86_64-615.71.09.run \(sh NVIDIA-Linux-x86_64-615.71.09.run -x\),\$"
  check "  and where to copy it" out_has "^copied to (.*/fake)?/lib/firmware/nvidia/615.71.09/\. Nothing changed\.\$"
  check "  status 1" eq "$RC" 1
  check "  nothing unloaded or loaded" eq "$(cat "$FAKE/calls")" ""
  check "  the stock driver still runs" eq "$(cat "$FAKE/sys/module/nvidia/srcversion")/$(cat "$FAKE/sys/module/nvidia_drm/srcversion")" "STOCK-nvidia/STOCK-nvidia-drm"
  sh_ p2p-install.sh --yes
  check "no GSP firmware: p2p-install.sh refuses before writing" out_has "^ABORT: GSP firmware not found: nvidia/615.71.09/gsp_ga10x.bin"
  check "  no backup, no module copied" test ! -e "$FAKE/var/backups/p2p-modules" -a ! -e "$FAKE/lib/modules/stand-in/updates"
  fw "$FAKE/lib/firmware" gsp_ga10x.bin
  sh_ p2p-load.sh --yes
  check "gsp without ucodes: refused, naming ucodes" out_has "^ABORT: GSP firmware not found: nvidia/615.71.09/ucodes_ga10x.bin\$"
  # firmware_class.path: the running value counts for a load, only the kernel command line for the boot install
  rm -rf "$FAKE/lib/firmware"; fw "$CDIR/extract" gsp_ga10x.bin ucodes_ga10x.bin
  mkdir -p "$FAKE/sys/module/firmware_class/parameters"; echo "$CDIR/extract" >"$FAKE/sys/module/firmware_class/parameters/path"
  sh_ p2p-load.sh --dry-run
  check "firmware_class.path: p2p-load.sh takes it" out_has "^GSP firmware: $CDIR/extract/nvidia/615.71.09/gsp_ga10x.bin\$"
  check "  and goes on" out_has "^\+ insmod .*/nvidia.ko "
  sh_ p2p-install.sh --dry-run
  check "running firmware_class.path only: p2p-install.sh refuses (the boot does not have it)" out_has "^firmware_class.path counts only when it is on the kernel command line\.\$"
  echo "BOOT_IMAGE=/vmlinuz root=/dev/sda1 firmware_class.path=$CDIR/extract quiet" >"$FAKE/proc/cmdline"
  sh_ p2p-install.sh --dry-run
  check "firmware_class.path on the kernel command line: p2p-install.sh takes it" out_has "^GSP firmware: $CDIR/extract/nvidia/615.71.09/ucodes_ga10x.bin\$"
  : >"$FAKE/sys/module/firmware_class/parameters/path"
  mkdir -p "$FAKE/lib/firmware/nvidia/615.71.09"
  echo fw >"$FAKE/lib/firmware/nvidia/615.71.09/gsp_ga10x.bin.zst"; echo fw >"$FAKE/lib/firmware/nvidia/615.71.09/ucodes_ga10x.bin.xz"
  sh_ p2p-load.sh --dry-run
  check "compressed firmware (.zst, .xz) counts" out_has "gsp_ga10x\.bin\.zst\$"
  check "  status 0" eq "$RC" 0
  # the chip family: a Turing card needs the tu10x files, also when it is not in GPUS but on nvidia
  card $C 1e07 Turing 11264 16384
  cfg "$A $C" ""
  sh_ p2p-load.sh --yes
  check "Turing card in GPUS: gsp_tu10x.bin and ucodes_tu10x.bin needed" out_has "^ABORT: GSP firmware not found: nvidia/615.71.09/gsp_tu10x.bin nvidia/615.71.09/ucodes_tu10x.bin\$"
  cfg "$A $B" ""
  ln -s "../../devices/$C" "$FAKE/sys/bus/pci/drivers/nvidia/$C"
  sh_ p2p-load.sh --yes
  check "Turing GPU on nvidia, not in GPUS: needed too" out_has "^ABORT: GSP firmware not found: nvidia/615.71.09/gsp_tu10x.bin"
  check "  nothing unloaded or loaded in any of it" eq "$(grep -c . "$FAKE/calls")" 0
  fw "$FAKE/lib/firmware" gsp_tu10x.bin ucodes_tu10x.bin
  sh_ p2p-load.sh --dry-run
  check "with the tu10x files: accepted" eq "$RC" 0
  lib "chip_fw_files GA100; chip_fw_files AD102; chip_fw_files TU116; chip_fw_files GB10B; chip_fw_files GB202"
  check "chip_fw_files per family (nv-firmware.h)" eq "$(tr '\n' '|' <"$CDIR/out")" "gsp_tu10x.bin ucodes_tu10x.bin|gsp_ga10x.bin ucodes_ga10x.bin|gsp_tu10x.bin ucodes_tu10x.bin|gsp_ga10x.bin|gsp_ga10x.bin ucodes_ga10x.bin|"
}
run_case 19-load-firmware "p2p-load.sh/p2p-install.sh: no GSP firmware refused before any change; firmware_class.path; families" c19

c20() {
  card $A 2206; card $B 2206; stock_loaded "$PD2"; cfg "$A $B" ""
  # an RM init failure of an earlier load is in the log already: it does not count
  echo "[    3.000000] NVRM: GPU $A: RmInitAdapter failed! (0x61:0x56:2036)" >"$FAKE/dmesg"
  printf '[  100.000000] NVRM: GPU %s: RmFetchGspRmImages: No firmware image found\n[  100.100000] NVRM: GPU %s: RmInitAdapter failed! (0x61:0x56:2036)\n[  100.200000] NVRM: GPU %s init failed during probe (ret=-5).\n' $A $A $A >"$FAKE/klog-nvidia"
  sh_ p2p-load.sh --yes
  check "RM init failed: said, with the new log lines only" eq "$(sed -n '/^RM INIT FAILED/,/^+ rmmod nvidia$/p' "$CDIR/out" | tr '\n' '|')" \
    "RM INIT FAILED after insmod nvidia; unloading it, nothing else is loaded:|[  100.100000] NVRM: GPU $A: RmInitAdapter failed! (0x61:0x56:2036)|[  100.200000] NVRM: GPU $A init failed during probe (ret=-5).|+ rmmod nvidia|"
  check "  module calls: unload stock, insmod nvidia, rmmod nvidia at once, back to stock" eq "$(sed 's/ NVreg.*//' "$FAKE/calls" | tr '\n' '|')" \
    "rmmod nvidia_drm|rmmod nvidia_modeset|rmmod nvidia_uvm|rmmod nvidia|insmod $WORK/out/nvidia.ko|rmmod nvidia|modprobe -v nvidia|modprobe -a nvidia_drm nvidia_uvm|"
  check "  back to stock through p2p-rollback.sh" out_has "^target: stock .*/nvidia.ko, by modprobe\$"
  check "  the stock driver runs" eq "$(cat "$FAKE/sys/module/nvidia/srcversion")" STOCK-nvidia
  check "  udev paused by the load, again by the rollback, resumed once; nothing blocked" eq "$(udev_calls)/$(test -e "$STOP" && echo blocked)" \
    "udevadm control --stop-exec-queue|udevadm control --stop-exec-queue|udevadm control --start-exec-queue|udevadm settle -t 30|/"
  reset_fake; card $A 2206; card $B 2206; stock_loaded "$PD2"
  echo "[  100.000000] NVRM: GPU $B init failed during probe (ret=-5)." >"$FAKE/klog-nvidia"
  sh_ p2p-load.sh --yes
  check "'init failed during probe' alone stops it too" eq "$(grep -c '^insmod .*nvidia-' "$FAKE/calls")/$(grep -c '^RM INIT FAILED' "$CDIR/out")" "0/1"
}
run_case 20-load-rm-init-failed "p2p-load.sh: RM init failed after insmod nvidia: only nvidia unloaded, nothing else loaded" c20

c21() {
  card $A 2206; card $B 2206; stock_loaded "$PD2"; cfg "$A $B" ""
  echo "[    3.000000] NVRM: GPU $A: RmInitAdapter failed! (0x61:0x56:2036)" >"$FAKE/dmesg"
  echo "[  100.000000] NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  615.71.09" >"$FAKE/klog-nvidia"
  sh_ p2p-load.sh --yes
  check "normal load: status 0, no failed check" eq "$RC/$(grep -c FAILED "$CDIR/out")" "0/0"
  check "  module calls: unload stock, load the four modules of the build" eq "$(sed 's/ NVreg.*//' "$FAKE/calls" | tr '\n' '|')" \
    "rmmod nvidia_drm|rmmod nvidia_modeset|rmmod nvidia_uvm|rmmod nvidia|insmod $WORK/out/nvidia.ko|insmod $WORK/out/nvidia-modeset.ko|insmod $WORK/out/nvidia-drm.ko|insmod $WORK/out/nvidia-uvm.ko uvm_disable_hmm=1|"
  check "  the build runs" eq "$(cat "$FAKE/sys/module/nvidia/srcversion")" SRC-nvidia
  check "  the firmware it found is listed" out_has "^GSP firmware: $FAKE/lib/firmware/nvidia/615.71.09/gsp_ga10x.bin\$"
}
run_case 21-load-normal "p2p-load.sh --yes from stock: firmware found, no RM init failure, the build loaded" c21

c22() {
  # memory-modded RTX 2080 Ti 22GB (TU102, BAR1 32 GiB) and RTX 4090 48GB (AD102, BAR1 64 GiB): opt-in chips
  cfg "" ""
  local chip dev arch vram bar fwf st
  v() { lib "pair_verdict '$1' $A $B; echo \"\$V_STATE|\$V_TEXT\""; cat "$CDIR/out"; }
  while read -r chip dev arch vram bar fwf; do
    reset_fake; card $A $dev "${arch/_/ }" $vram $bar; card $B $dev "${arch/_/ }" $vram $bar
    lib "chip_check $A; echo \"\$C_CHIP|\$C_CLASS|\$(chip_fw_files \$C_CHIP)\""
    check "$chip ${vram} MiB: opt-in, GSP firmware $fwf" eq "$(cat "$CDIR/out")" "$chip|opt-in|gsp_$fwf.bin ucodes_$fwf.bin"
    check "$chip pair without the key: untested, both cards named" eq "$(v "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;")" \
      "untested|untested ($chip + $chip): run p2p-check.sh --integrity on a trial load (README, Opt-in), then enable with: p2p-enable.sh --yes $A $B"
    check "$chip pair with the key: opted in" eq "$(v "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;")" \
      "opted-in|opted in (on, $chip + $chip: RMDynBar1P2PEnable=1; not verified yet, please send a compatibility report)"
    st=$(v "pci=$A;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;")
    check "$chip pair, static BAR1 on one card (key set): untested, that card named" eq "${st%%;*}" \
      "untested|untested ($chip + $chip): run p2p-check.sh --integrity on a trial load (README, Opt-in), then enable with: p2p-enable.sh --yes $A"
    check "  with the static BAR1 note" eq "${st#*; }" "static BAR1 on $A (no RMForceStaticBar1=0: geforce-bar1-resize sets it by default only for cards it enlarges through 0x610, dynamic BAR1 P2P needs it; p2p-enable.sh also sets driver_option=on for the card)"
    reset_fake; card $A $dev "${arch/_/ }" $vram $((bar / 2)); card $B $dev "${arch/_/ }" $vram $bar
    check "$chip with half the BAR1 ($((bar / 2)) MiB < $vram MiB): not supported" eq "$(v "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;")" \
      "unsupported|not supported (BAR1 of $A is $((bar / 2)) MiB, smaller than its $vram MiB of VRAM (geforce-bar1-resize enlarges it))"
  done <<<"TU102 1e04 Turing 22528 32768 tu10x
AD102 2684 Ada_Lovelace 49152 65536 ga10x"
}
run_case 22-modded-tu102-ad102 "RTX 2080 Ti 22GB (TU102) and RTX 4090 48GB (AD102) pairs: opt-in, key, static BAR1, BAR1 < VRAM" c22

# the per-device string without RMForceStaticBar1=0, which p2p-rollback.sh refuses to load a driver with
PD_NOSTATIC="pci=$A;pci=$B;"
c23() {
  # p2p-load.sh hands over to p2p-rollback.sh with udev paused; the rollback refuses before its own pause while no
  # nvidia module is loaded: every nvidia module blocked, then udev resumed and the console bound again
  card $A 2206; card $B 2206; stock_loaded "$PD2"; cfg "$A $B" ""; echo "VTCON=$CDIR/vtcon" >>"$CDIR/config.sh"
  modprobe_line "$PD_NOSTATIC"
  echo "[  100.000000] NVRM: GPU $A init failed during probe (ret=-5)." >"$FAKE/klog-nvidia"
  sh_ p2p-load.sh --yes
  check "handover, nvidia unloaded, the rollback refuses: the refusal" out_has "^ABORT: restore the RMForceStaticBar1=0 option before loading a driver\$"
  check "  then the stop, nothing loaded" out_has "^ABORT: the rollback stopped before loading a driver; no nvidia driver is loaded\.\$"
  check "  lsmod after udev resumed: no nvidia module" out_has "^  no nvidia module\$"
  check "  status 1" eq "$RC" 1
  check "  udev resumed after the pause" eq "$(udev_calls)" "udevadm control --stop-exec-queue|udevadm control --start-exec-queue|udevadm settle -t 30|"
  check "  console bound again" eq "$(cat "$CDIR/vtcon")" 1
  check "  every nvidia module blocked" eq "$(grep -c '^install nvidia[-_a-z]* /bin/false$' "$STOP" 2>/dev/null)" 9
  check "  nothing loaded after rmmod nvidia" eq "$(sed 's/ NVreg.*//' "$FAKE/calls" | tr '\n' '|')" \
    "rmmod nvidia_drm|rmmod nvidia_modeset|rmmod nvidia_uvm|rmmod nvidia|insmod $WORK/out/nvidia.ko|rmmod nvidia|"
  # the same refusal without a handover: udev never paused, nothing blocked
  reset_fake; card $A 2206; card $B 2206; stock_loaded "$PD2"; modprobe_line "$PD_NOSTATIC"
  sh_ p2p-rollback.sh --yes
  check "rollback alone refuses the same way" eq "$RC/$(grep -c '^ABORT' "$CDIR/out")" "1/1"
  check "  udev untouched, nothing blocked" eq "$(udev_calls)/$(test -e "$STOP" && echo blocked)" "/"
  # a rollback alone from the build: paused once, resumed once, nothing blocked
  reset_fake; card $A 2206; card $B 2206; stock_loaded "$PD2"; params "$PD2"
  sh_ p2p-rollback.sh --yes
  check "rollback alone from the build: stock loaded" eq "$RC/$(cat "$FAKE/sys/module/nvidia/srcversion")" "0/STOCK-nvidia"
  check "  udev paused and resumed once, nothing blocked" eq "$(udev_calls)/$(test -e "$STOP" && echo blocked)" \
    "udevadm control --stop-exec-queue|udevadm control --start-exec-queue|udevadm settle -t 30|/"
}
run_case 23-handover-unloaded "p2p-load.sh -> p2p-rollback.sh: a refusal with no nvidia loaded blocks nvidia, resumes udev" c23

c24() {
  # a check of the build fails (all four modules loaded), so p2p-load.sh hands over; the rollback refuses before its
  # own pause: udev resumed, nothing blocked, the build left loaded
  card $A 2206; card $B 2206; stock_loaded "$PD2"; cfg "$A $B" ""; echo "VTCON=$CDIR/vtcon" >>"$CDIR/config.sh"
  modprobe_line "$PD_NOSTATIC"
  sed -i 's/^EnableResizableBar: 0$/EnableResizableBar: 1/' "$FAKE/proc/driver/nvidia/params"
  sh_ p2p-load.sh --yes
  check "failed check, handover, the rollback refuses" eq "$(grep -c '^CHECK FAILED EnableResizableBar' "$CDIR/out")/$(grep -c '^ABORT: restore the RMForceStaticBar1=0' "$CDIR/out")" "1/1"
  check "  no stop of its own, status 1" eq "$(grep -c '^ABORT: the rollback stopped' "$CDIR/out")/$RC" "0/1"
  check "  udev resumed after the pause, console bound again" eq "$(udev_calls)$(cat "$CDIR/vtcon")" \
    "udevadm control --stop-exec-queue|udevadm control --start-exec-queue|udevadm settle -t 30|1"
  check "  nothing blocked" test ! -e "$STOP"
  check "  the build stays loaded" eq "$(cat "$FAKE/sys/module/nvidia/srcversion")/$(cat "$FAKE/sys/module/nvidia_uvm/srcversion")" "SRC-nvidia/SRC-nvidia_uvm"
}
run_case 24-handover-loaded "p2p-load.sh -> p2p-rollback.sh: a refusal with nvidia loaded resumes udev, blocks nothing" c24

c25() {
  # Ubuntu's prebuilt-module packages leave kernel/nvidia-<branch>/bits/ behind after a switch to another driver
  # (nvidia.ko.sig from linux-signatures-nvidia-<kernel>, .o files from linux-objects-nvidia-<branch>-<kernel>), and a
  # whole module of another branch can stay too: the stock module is still the 615.71.09 one
  card $A 2206; card $B 2206; stock_loaded "$PD2"; cfg "$A $B" ""
  local K=$FAKE/lib/modules/stand-in/kernel
  mkdir -p "$K/nvidia-595/bits" "$K/nvidia-595-open"
  : >"$K/nvidia-595/bits/nvidia.ko.sig"; : >"$K/nvidia-595/bits/nvidia-uvm.ko.sig"; : >"$K/nvidia-595/bits/nvidia.mod.o"
  printf 'srcversion=OTHER-nvidia\nvermagic=stand-in SMP\nversion=595.58.03\ndepends=\n' >"$K/nvidia-595-open/nvidia.ko"
  lib 'ko_in "$KDIR/kernel/nvidia-595/bits" nvidia; echo "[$(ko_in "$KDIR/kernel/drivers/video" nvidia-uvm)]"'
  check "ko_in: a .sig next to it is not a module" eq "$(cat "$CDIR/out")" "[$K/drivers/video/nvidia-uvm.ko]"
  lib 'stock_dir'
  check "stock_dir: the 615.71.09 module, not bits/ and not the 595 module" eq "$(cat "$CDIR/out")" "$K/drivers/video"
  sh_ p2p-load.sh --dry-run
  check "p2p-load.sh plan starts from the stock driver" out_has "^start: the stock driver \($K/drivers/video\)\$"
  rm -r "$K/drivers"
  lib 'stock_dir'
  check "stock_dir with only another branch's module: that one (its version is checked where it matters)" eq "$(cat "$CDIR/out")" "$K/nvidia-595-open"
}
run_case 25-leftover-prebuilt "stock_dir/ko_in next to Ubuntu's leftover bits/ (.sig, .o) and another branch's module" c25

# on_root_port ROOT-PORT VENDOR DEVICE CARD...: a root port (ids in hex without 0x) below its host bridge in the fake
# /sys/devices, with the cards (made with card) moved below it, linked from /sys/bus/pci/devices as on a real system
on_root_port() {
  local rp=$1 ven=$2 dev=$3 host b
  shift 3
  host=$FAKE/sys/devices/pci${rp%:*}
  mkdir -p "$host/$rp"; echo "0x$ven" >"$host/$rp/vendor"; echo "0x$dev" >"$host/$rp/device"
  ln -sfn "$host/$rp" "$FAKE/sys/bus/pci/devices/$rp"
  for b in "$@"; do
    mv "$FAKE/sys/bus/pci/devices/$b" "$host/$rp/$b" && ln -sfn "$host/$rp/$b" "$FAKE/sys/bus/pci/devices/$b"
  done
}
c26() {
  # an outside report: RTX 2080 Ti 22GB cards on root ports of different Broadwell-EX sockets (8086:6f08,
  # 8086:6f04); the driver refuses such pairs as stock does (TNS), the scripts must say why and not expect OK
  local D=0000:41:00.0 pd v
  cfg "" ""
  card $A 1e07 Turing 22528 32768; card $B 1e07 Turing 22528 32768; card $D 1e07 Turing 22528 32768
  on_root_port 0000:00:03.0 8086 6f08 $A; on_root_port 0000:00:02.0 8086 6f04 $B; on_root_port 0000:40:02.0 8086 6f04 $D
  pd="pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$D;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;"
  v() { lib "pair_verdict '$1' $2 $3; echo \"\$V_STATE|\$V_TEXT\""; cat "$CDIR/out"; }
  lib "root_port $A; root_port $D"
  check "root_port: the first device below the host bridge" eq "$(tr '\n' ' ' <"$CDIR/out")" "0000:00:03.0 0000:40:02.0 "
  v=$(v "$pd" $A $D)
  check "two Broadwell sockets: not supported" eq "${v%%|*}" unsupported
  check "  names both root ports" eq "$(grep -o 'two Intel CPU sockets, root ports [^;]*' <<<"$v")" "two Intel CPU sockets, root ports 0000:00:03.0 and 0000:40:02.0"
  check "  says the driver refuses it as stock does (TNS)" eq "$(grep -c "as NVIDIA's own does: TNS in nvidia-smi topo -p2p" <<<"$v")" 1
  check "two root ports of one socket (same bus): opted in" eq "$(v "$pd" $A $B | cut -d'|' -f1)" opted-in
  reset_fake; card $A 1e07 Turing 22528 32768; card $D 1e07 Turing 22528 32768
  on_root_port 0000:00:01.0 8086 2030 $A; on_root_port 0000:40:01.0 8086 2030 $D
  check "Skylake-SP root ports on two sockets: not in the driver's list, opted in" eq "$(v "$pd" $A $D | cut -d'|' -f1)" opted-in
  reset_fake; card $A 1e07 Turing 22528 32768; card $D 1e07 Turing 22528 32768
  on_root_port 0000:00:03.0 8086 6f08 $A; on_root_port 0000:40:01.1 1022 1483 $D
  check "one listed Intel root port, one other: not refused (as in the driver)" eq "$(v "$pd" $A $D | cut -d'|' -f1)" opted-in
  # the check and --integrity on the refused pair: TNS is expected, the pair is skipped
  reset_fake; card $A 1e07 Turing 22528 32768; card $D 1e07 Turing 22528 32768
  on_root_port 0000:00:03.0 8086 6f08 $A; on_root_port 0000:40:02.0 8086 6f04 $D
  cfg "$A $D" 1
  full_setup "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$D;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;" TNS
  sh_ p2p-check.sh --pairs
  check "--pairs: the refused pair with both root ports" out_has "^$A <-> $D: not supported \(TU102 \+ TU102: the cards sit on two Intel CPU sockets, root ports 0000:00:03.0 and 0000:40:02.0;"
  sh_ p2p-check.sh
  check "the check: TNS for the refused pair is no FAIL" out_has "^topo -p2p r $A <-> $D: TNS \(pair unsupported: no expectation\)\$"
  check "  ALL PASS" eq "$RC/$(grep -c '^ALL PASS$' "$CDIR/out")" "0/1"
  standin_integrity
  sh_ p2p-check.sh --integrity
  check "--integrity: the refused pair is skipped, not run" out_has "^SKIP $A <-> $D: not tested \(the pair is unsupported\)\$"
}
run_case 26-cpu-sockets "pairs on two Intel CPU sockets refused as in stock (TNS): verdict, the check, --integrity" c26


c10() {
  card $A 2206; card $B 2206; card $C 2206
  cfg "$A $B" ""
  printf 'GPUS="%s"\nKVER=stand-in\nP2P_ENABLE=\n' "$A $B" >"$SRC/contrib/3080-20g/config.sh"
  modprobe_line "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
  touch "$FAKE/smi/off"
  echo "\$ contrib/3080-20g/p2p-check.sh --pairs" >>"$LOG"
  "$SRC/contrib/3080-20g/p2p-check.sh" --pairs >"$CDIR/out" 2>&1; RC=$?
  sed 's/^/  | /' "$CDIR/out" >>"$LOG"
  check "old entry point runs the new script (no driver: VRAM unknown, so untested)" out_has "^$A <-> $B: on by default, untested \(GA102 \+ GA102"
  check "old entry point: note on stderr" out_has '^note: contrib/3080-20g/ is deprecated'
  check "old entry point uses the old config.sh (its GPUS, not every card)" out_hasnt "^$C "
  local s; for s in p2p-load p2p-install p2p-rollback p2p-fallback; do
    check "old $s.sh is the wrapper" cmp "$PUB/contrib/3080-20g/p2p-check.sh" "$PUB/contrib/3080-20g/$s.sh"
    check "new $s.sh exists" test -x "$PUB/contrib/$s.sh"
  done
}
run_case 10-old-entry-points "contrib/3080-20g/: wrappers with the old config.sh, for one release" c10

c11() {
  mkdir -p "$CDIR/nv/bin"
  cat >"$CDIR/nv/bin/nvcc" <<EOF
#!/bin/bash
[ "\$1" = --version ] && { echo "Cuda compilation tools, release 99.0, V99.0.0"; exit 0; }
[ "\$1" = --list-gpu-arch ] && { printf 'compute_75\ncompute_80\ncompute_86\n'; exit 0; }
echo "\$*" >"$CDIR/nvcc-args"
o=""; prev=""; for a; do [ "\$prev" != -o ] || o=\$a; prev=\$a; done
printf '#!/bin/sh\n[ "\$1" = --selftest ]\n' >"\$o"; chmod 755 "\$o"
EOF
  chmod 755 "$CDIR/nv/bin/nvcc"
  echo "\$ build.sh (fake nvcc)" >>"$LOG"
  NVCC=$CDIR/nv/bin/nvcc "$SRC/contrib/integrity/build.sh" "$CDIR/p2p-integrity" >"$CDIR/out" 2>&1; RC=$?
  sed 's/^/  | /' "$CDIR/out" >>"$LOG"
  check "build: status 0" eq "$RC" 0
  check "only the architectures nvcc knows, PTX of the lowest" eq "$(grep -o 'arch=[^ ]*' "$CDIR/nvcc-args" | tr '\n' ' ')" \
    "arch=compute_75,code=sm_75 arch=compute_80,code=sm_80 arch=compute_86,code=sm_86 arch=compute_75,code=compute_75 "
  check "last line: the binary" eq "$(tail -1 "$CDIR/out")" "$CDIR/p2p-integrity"
  echo "\$ build.sh (no nvcc)" >>"$LOG"
  env -u NVCC PATH="$BIN:/usr/bin:/bin" "$SRC/contrib/integrity/build.sh" "$CDIR/x" >"$CDIR/out" 2>&1; RC=$?
  sed 's/^/  | /' "$CDIR/out" >>"$LOG"
  check "no nvcc: status 2" eq "$RC" 2
  check "no nvcc: says what to install" out_has '^nvcc not found: install the CUDA toolkit'
}
run_case 11-build-script "integrity/build.sh: nvcc detection, architectures, no nvcc" c11

c90() {
  command -v shellcheck >/dev/null || { SKIP="no shellcheck"; return 0; }
  echo "\$ shellcheck -x -S style (in contrib/ and tests/contrib/)" >>"$LOG"
  check "shellcheck contrib/" bash -c 'cd "$1/contrib" && shellcheck -x -S style ./*.sh 3080-20g/*.sh integrity/build.sh' _ "$PUB"
  check "shellcheck tests/contrib/run.sh" bash -c 'cd "$1/tests/contrib" && shellcheck -x -S style run.sh' _ "$PUB"
}
run_case 90-shellcheck "shellcheck -S style clean" c90

c91() {
  local nvcc=${NVCC:-} c
  if [ -z "$nvcc" ]; then
    nvcc=$(PATH=$REAL_PATH command -v nvcc || true)
    for c in /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc; do [ -n "$nvcc" ] || [ ! -x "$c" ] || nvcc=$c; done
  fi
  [ -n "$nvcc" ] || { SKIP="no nvcc"; return 0; }
  echo "\$ NVCC=$nvcc contrib/integrity/build.sh" >>"$LOG"
  NVCC=$nvcc PATH=$REAL_PATH "$PUB/contrib/integrity/build.sh" "$CDIR/p2p-integrity" >"$CDIR/out" 2>&1; RC=$?
  sed 's/^/  | /' "$CDIR/out" >>"$LOG"
  check "p2p-integrity.cu compiles with $nvcc" eq "$RC" 0
  "$CDIR/p2p-integrity" --selftest >"$CDIR/out" 2>&1; RC=$?
  sed 's/^/  | /' "$CDIR/out" >>"$LOG"
  check "--selftest (host only, no GPU)" eq "$RC/$(tail -1 "$CDIR/out")" "0/selftest ok"
  check "--selftest plan reaches 4 GiB with guard bands" out_has ' 4 GiB\[2101256, -2101256\]$'
  check "--selftest: the default plan has GATE_CASES cases (contrib/common.sh)" out_has "^cases $(sed -n 's/^GATE_MAXMIB=4096 GATE_CASES=\([0-9]*\)$/\1/p' "$PUB/contrib/common.sh")\$"
  "$CDIR/p2p-integrity" --pair 0000:01:00.0 >"$CDIR/out" 2>&1; RC=$?
  check "usage error: status 2" eq "$RC" 2
}
run_case 91-integrity-build "p2p-integrity.cu with a real nvcc, host-only --selftest" c91

echo
printf '%-24s %-4s %s\n' case res checked
printf '%s\n' "${ROWS[@]}"
echo "${#ROWS[@]} cases: $((${#ROWS[@]} - FAILS - SKIPS)) passed, $FAILS failed, $SKIPS skipped"
if [ "$FAILS" = 0 ] && [ "$OWN_WORK" = 1 ]; then rm -rf "$WORK"; else echo "logs: $WORK/cases"; fi
[ "$FAILS" -le 125 ] || FAILS=125
exit "$FAILS"
