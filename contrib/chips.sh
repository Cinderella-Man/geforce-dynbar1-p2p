# shellcheck shell=bash disable=SC2034  # C_* and V_* are read by the scripts that source this file
# SPDX-License-Identifier: MIT
# Sourced by common.sh: which chip a card is, what this driver does for it, and the verdict for a pair of cards.
#
# Chip of a card: its PCI device id. NVIDIA gives each chip its own block of 0x80 device ids; the blocks below are
# taken from the PCI ID database (pci.ids, 2026-10-31: every display and 3D controller entry of 10de from 1e00 on falls
# in the block of its chip). When nvidia-smi answers, its "Product Architecture" must agree, otherwise the chip counts
# as unknown.
#
# Classes (C_CLASS of a card):
#   verified    the card it was tested on: RTX 3080 20GB (GA102, 10de:2206 with 20 GB of VRAM); P2P on by default
#   default     every other GA102 card: P2P on by default (the driver arms GA102 itself), but untested until reported
#   opt-in      Turing, other Ampere, Ada: the same driver route, armed only by RMDynBar1P2PEnable=1 for the card,
#               after the --integrity test passed (README, Opt-in)
#   stock       GeForce Blackwell (GB20x): NVIDIA's own driver already offers BAR1 P2P; this driver leaves it stock
#   datacenter  GA100, GH100, GB10x/GB11x/GB12x: not a target of this driver patch
CHIP_BLOCKS="1e00 TU102
1e80 TU104
1f00 TU106
1f80 TU117
2080 GA100
2180 TU116
2200 GA102
2300 GH100
2380 GH100
2400 GA103
2480 GA104
2500 GA106
2580 GA107
2680 AD102
2700 AD103
2780 AD104
2800 AD106
2880 AD107
2900 GB100
2980 GB102
2b00 GB10B
2b80 GB202
2c00 GB203
2d00 GB206
2d80 GB207
2e00 GB20B
2f00 GB205
3180 GB110
3200 GB112
3300 GB120
3400 GB10B"

# chip_of_device <hex device id>: the chip, or nothing.
chip_of_device() {
  local d=$((16#${1#0x})) start chip
  while read -r start chip; do
    [ "$d" -ge $((16#$start)) ] && [ "$d" -lt $((16#$start + 0x80)) ] && { echo "$chip"; return 0; }
  done <<<"$CHIP_BLOCKS"
  return 1
}
chip_arch() {
  case $1 in TU*) echo Turing ;; GA*) echo Ampere ;; AD*) echo "Ada Lovelace" ;; GH*) echo Hopper ;; GB*) echo Blackwell ;; esac
}
chip_class() {
  case $1 in
    GA102) echo default ;;
    TU10[246] | TU11[67] | GA10[3467] | AD10[23467]) echo opt-in ;;
    GB20[23567]) echo stock ;;
    *) echo datacenter ;;
  esac
}
# chip_fw_files <chip>: the GSP firmware files the open driver loads for the chip, from nvidia/<version>/
# (kernel-open/common/inc/nv-firmware.h and src/nvidia/arch/nvalloc/common/inc/nv-firmware-chip-family-select.h):
# family tu10x for Turing and GA100, ga10x for every later chip; GB10B has no ucodes file.
chip_fw_files() {
  case $1 in
    TU* | GA100) echo gsp_tu10x.bin ucodes_tu10x.bin ;;
    GB10B) echo gsp_ga10x.bin ;;
    ?*) echo gsp_ga10x.bin ucodes_ga10x.bin ;;
  esac
}

# rd <file>: one sysfs value, lower case, without 0x.
rd() { local v; v=$(cat "$1" 2>/dev/null) || return 1; v=${v,,}; echo "${v#0x}"; }
# card_ids <address>: vendor:device/subvendor:subdevice, the form geforce-bar1-resize's ids= uses.
card_ids() {
  local d=/sys/bus/pci/devices/$1
  echo "$(rd "$d/vendor"):$(rd "$d/device")/$(rd "$d/subsystem_vendor"):$(rd "$d/subsystem_device")"
}
# Every NVIDIA display or 3D controller function, in address order.
detect_gpus() {
  local d c
  for d in /sys/bus/pci/devices/*; do
    [ "$(rd "$d/vendor")" = 10de ] || continue
    c=$(rd "$d/class"); case $c in 0300* | 0302*) basename "$d" ;; esac
  done
}
# smi_arch <address>: nvidia-smi's Product Architecture of the card, or nothing (no nvidia-smi, driver not loaded).
smi_arch() {
  command -v nvidia-smi >/dev/null || return 0
  nvidia-smi -q -i "$1" 2>/dev/null | awk -F': ' '/^ *Product Architecture/ { print $2; exit }'
}

# chip_check <address>: sets C_IDS, C_CHIP, C_CLASS (verified, default, opt-in, stock, datacenter, unknown) and C_WHY
# (why the chip is unknown).
chip_check() {
  local d=/sys/bus/pci/devices/$1 dev smi vr
  C_IDS=$(card_ids "$1") C_CHIP="" C_CLASS=unknown C_WHY=""
  if [ "$(rd "$d/vendor")" != 10de ]; then C_WHY="no NVIDIA device at $1"; return 0; fi
  case $(rd "$d/class") in 0300* | 0302*) ;; *) C_WHY="$1 is not a display or 3D controller"; return 0 ;; esac
  dev=$(rd "$d/device")
  C_CHIP=$(chip_of_device "$dev") || { C_WHY="device id 10de:$dev is in no known chip block"; return 0; }
  smi=$(smi_arch "$1")
  if [ -n "$smi" ] && [ "$smi" != "$(chip_arch "$C_CHIP")" ]; then
    C_WHY="device id 10de:$dev says $C_CHIP ($(chip_arch "$C_CHIP")), nvidia-smi says $smi"; C_CHIP=""; return 0
  fi
  C_CLASS=$(chip_class "$C_CHIP")
  # the tested card: RTX 3080 (10de:2206) memory-modded to 20 GB; VRAM unknown (no driver) counts as untested
  if [ "$dev" = 2206 ] && vr=$(vram_mib "$1") && [ -n "$vr" ] && [ "$vr" -ge 20000 ]; then C_CLASS=verified; fi
}

# card_key <per-device string> <address> <key>: the value the driver uses (the last one in the card's group), or
# nothing when the key is not set for the card.
card_key() {
  local s v
  [[ $1 == *"pci=$2;"* ]] || return 0
  s=${1#*"pci=$2;"}; s=";${s%%pci=*}"
  [[ $s == *";$3="* ]] || return 0
  v=${s##*";$3="}; echo "${v%%;*}"
}

# bar1_mib <address>: size of BAR1 (resource line 2) in MiB.
bar1_mib() {
  local s e _
  { read -r _; read -r s e _; } <"/sys/bus/pci/devices/$1/resource" 2>/dev/null || return 1
  [ "$((s))" != 0 ] || return 1
  echo $(((e - s + 1) >> 20))
}
# vram_mib <address>: VRAM from nvidia-smi, or nothing.
vram_mib() {
  local v
  command -v nvidia-smi >/dev/null || return 0
  v=$(nvidia-smi -i "$1" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null) || return 0
  [[ $v =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]] && echo "${BASH_REMATCH[1]}"
}

# pair_verdict <per-device string> <address A> <address B>: sets V_STATE and V_TEXT. V_STATE:
#   verified    both cards RTX 3080 20GB, P2P on by default
#   default     on by default (GA102) but at least one card is not the verified RTX 3080 20GB: untested
#   opted-in    on: every card that is not GA102 has RMDynBar1P2PEnable=1
#   untested    a card of an opt-in chip lacks RMDynBar1P2PEnable=1, or a card has static BAR1 (no RMForceStaticBar1=0;
#               p2p-enable.sh sets driver_option=on in geforce-bar1-resize's config for it)
#   off         a card has RMDynBar1P2PEnable set to something other than 1
#   stock       GeForce Blackwell: NVIDIA's own BAR1 P2P, left alone
#   unsupported anything else; V_TEXT says why
# The per-device string is the one the driver uses (the running driver's, or the one modprobe reads at the next load).
pair_verdict() {
  local pd=$1 a=$2 b=$3 g k arch="" chips="" need="" off="" why="" st="" bar vram
  local -A cls=()
  V_STATE=unsupported V_TEXT=""
  for g in "$a" "$b"; do
    chip_check "$g"
    [ "$C_CLASS" != unknown ] || { V_TEXT="not supported (unknown chip: $C_WHY)"; return 0; }
    [ "$C_CLASS" != datacenter ] || { V_TEXT="not supported ($C_CHIP at $g is a datacenter chip, not a target of this driver patch)"; return 0; }
    cls[$g]=$C_CLASS chips+="${chips:+ + }$C_CHIP"
    if [ -z "$arch" ]; then arch=$(chip_arch "$C_CHIP")
    elif [ "$arch" != "$(chip_arch "$C_CHIP")" ]; then
      V_TEXT="not supported ($chips: CUDA itself refuses peer access between $arch and $(chip_arch "$C_CHIP") GPUs)"; return 0
    fi
  done
  if [ "${cls[$a]}" = stock ] || [ "${cls[$b]}" = stock ]; then
    V_STATE=stock
    V_TEXT="stock ($chips: NVIDIA's own driver offers BAR1 P2P on GB20x, this driver leaves the pair as stock"
    for g in "$a" "$b"; do
      [ "$(card_key "$pd" "$g" RMForceStaticBar1)" != 0 ] || why+=" $g"
    done
    [ -z "$why" ] || V_TEXT+="; stock BAR1 P2P needs static BAR1, which RMForceStaticBar1=0 turns off for$why (driver_option=off for the card in geforce-bar1-resize)"
    V_TEXT+=")"
    return 0
  fi
  for g in "$a" "$b"; do
    k=$(card_key "$pd" "$g" RMDynBar1P2PEnable)
    if [ -n "$k" ] && [ "$k" != 1 ]; then off+=" $g"; continue; fi
    [ "$(card_key "$pd" "$g" RMForceStaticBar1)" = 0 ] || st+=" $g"
    if [ "${cls[$g]}" = opt-in ] && [ "$k" != 1 ] || [[ $st == *" $g" ]]; then need+=" $g"; fi
    if bar=$(bar1_mib "$g") && vram=$(vram_mib "$g") && [ -n "$vram" ] && [ "$bar" -lt "$vram" ]; then
      why+="; BAR1 of $g is $bar MiB, smaller than its $vram MiB of VRAM (geforce-bar1-resize enlarges it)"
    fi
  done
  if [ -n "$off" ]; then V_STATE=off V_TEXT="off ($chips: RMDynBar1P2PEnable is set and not 1 for${off})"; return 0; fi
  if [ -n "$why" ]; then V_TEXT="not supported (${why#; })"; return 0; fi
  if [ -n "$need" ]; then
    V_STATE=untested
    V_TEXT="untested ($chips): run p2p-check.sh --integrity on a trial load (README, Opt-in), then enable with: p2p-enable.sh --yes${need}"
    [ -z "$st" ] || V_TEXT+="; static BAR1 on${st} (no RMForceStaticBar1=0: geforce-bar1-resize sets it by default only for cards it enlarges through 0x610, dynamic BAR1 P2P needs it; p2p-enable.sh also sets driver_option=on for the card)"
    return 0
  fi
  if [ "${cls[$a]}" = verified ] && [ "${cls[$b]}" = verified ]; then V_STATE=verified V_TEXT="verified (on, $chips: RTX 3080 20GB)"
  elif [ "${cls[$a]}" = opt-in ] || [ "${cls[$b]}" = opt-in ]; then
    V_STATE=opted-in V_TEXT="opted in (on, $chips: RMDynBar1P2PEnable=1; not verified yet, please send a compatibility report)"
  else
    V_STATE=default
    V_TEXT="on by default, untested ($chips: only the RTX 3080 20GB is verified): run p2p-check.sh --integrity once and please send a compatibility report"
  fi
}
