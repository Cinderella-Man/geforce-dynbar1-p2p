#!/bin/bash
# Read-only check after a boot (or after p2p-load.sh): which build is loaded, its options, BAR1, the chip of each card,
# the verdict for each pair, P2P as the driver reports it, and the kernel log. Loads nothing and writes nothing.
# Exit status = number of FAIL lines.
#   --pairs       only the cards (chip, BAR1, VRAM, RMDynBar1P2PEnable) and the verdict for each pair: verified (on),
#                 opted in (on), untested (run --integrity, then enable), off, stock, not supported (why). No root
#                 needed; with GPUS empty, every NVIDIA display or 3D controller.
#   --integrity   the check, then for each pair the byte-exact copy test and the bandwidth (integrity/p2p-integrity,
#                 built with nvcc on first use). It creates CUDA contexts and allocates up to --max-mib (default 4096)
#                 per card: run it with the GPUs otherwise idle. Writes the whole output, plus a short system summary
#                 (no serial numbers or UUIDs), to /var/lib/geforce-dynbar1-p2p/reports/<time>/report.txt for a
#                 compatibility report, and records each PASS in /var/lib/geforce-dynbar1-p2p/integrity-pass, which
#                 p2p-enable.sh looks for.
# Usage: p2p-check.sh [--pairs | --integrity [--max-mib N]]
set -u
export LC_ALL=C
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
ARGS=("$@") MODE=check MAXMIB=4096
usage() { echo "usage: $0 [--pairs | --integrity [--max-mib N]]"; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --pairs) MODE=pairs ;;
    --integrity) MODE=integrity ;;
    --max-mib) [[ ${2:-} =~ ^[0-9]+$ ]] && [ "$2" -ge 4 ] && [ "$2" -le 65536 ] || usage; MAXMIB=$2; shift ;;
    *) usage ;;
  esac
  shift
done
FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
want() { local p=$1 f=$2; shift 2; if "$@"; then pass "$p"; else fail "$f"; fi; }
# shellcheck disable=SC2329  # called through want
ge() { [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] && [ "$1" -ge "$2" ]; }
declare -A VSTATE=()

# show_pairs <per-device string> <address>...: each card's chip and the verdict for each pair (into VSTATE).
show_pairs() {
  local pd=$1 g a b bar vr live boot
  shift
  live=$(live_pd) boot=$(boot_pd)
  echo "== cards and pairs"
  for g in "$@"; do
    chip_check "$g"; bar=$(bar1_mib "$g") || bar="?"; vr=$(vram_mib "$g")
    echo "$g $C_IDS ${C_CHIP:-?} ($C_CLASS${C_WHY:+: $C_WHY}), BAR1 $bar MiB, VRAM ${vr:-?} MiB," \
      "RMDynBar1P2PEnable running '$(card_key "$live" "$g" RMDynBar1P2PEnable)' next load '$(card_key "$boot" "$g" RMDynBar1P2PEnable)'"
  done
  [ $# -ge 2 ] || echo "(fewer than two cards: no pairs)"
  while read -r a b; do
    pair_verdict "$pd" "$a" "$b"
    VSTATE["$a $b"]=$V_STATE
    echo "$a <-> $b: $V_TEXT"
  done < <(pairs "$@")
}

if [ "$MODE" = pairs ]; then
  [ -n "$GPUS" ] || GPUS=$(detect_gpus | tr '\n' ' ')
  [ -n "$GPUS" ] || die "no NVIDIA display or 3D controller found"
  for g in $GPUS; do valid_bdf "$g" || die "GPUS: '$g' is not $BDF_FORM"; done
  pd=$(live_pd)
  if [ -n "$pd" ]; then echo "(per-card options of the running driver)"; else pd=$(boot_pd); echo "(driver not loaded: per-card options of the next load)"; fi
  # shellcheck disable=SC2086  # GPUS is a list of addresses
  show_pairs "$pd" $GPUS
  exit 0
fi

[ "$(id -u)" = 0 ] || die "must run as root"
[ -n "$GPUS" ] || die "set GPUS in $CONFIG"
for g in $GPUS; do valid_bdf "$g" || die "GPUS: '$g' is not $BDF_FORM"; done
# --integrity: run again with the output also written to the report.
if [ "$MODE" = integrity ] && [ -z "${P2P_REPORT:-}" ]; then
  rdir=$STATE_DIR/reports/$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$rdir" || die "cannot create $rdir"
  P2P_REPORT=$rdir/report.txt "$0" "${ARGS[@]}" 2>&1 | tee "$rdir/report.txt"
  exit "${PIPESTATUS[0]}"
fi

if [ "$MODE" = integrity ]; then
  echo "== system (p2p-check.sh --integrity, $(date -u +%Y-%m-%dT%H:%MZ))"
  echo "kernel $(uname -r); IOMMU options: $(grep -oE '(intel_iommu|amd_iommu|iommu|iommu\.passthrough|pcie_acs_override)=[^ ]*' /proc/cmdline | tr '\n' ' ')"
  echo "CPU: $(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo); board: $(cat /sys/class/dmi/id/board_vendor /sys/class/dmi/id/board_name 2>/dev/null | tr '\n' ' ')"
  for g in $GPUS; do
    d=/sys/bus/pci/devices/$g
    echo "$g PCIe path $(readlink -f "$d" | sed 's|^/sys/devices/||'), link $(cat "$d/current_link_speed" 2>/dev/null) x$(cat "$d/current_link_width" 2>/dev/null) (max $(cat "$d/max_link_speed" 2>/dev/null) x$(cat "$d/max_link_width" 2>/dev/null))"
  done
  nvidia-smi --query-gpu=index,pci.bus_id,name,vbios_version,memory.total --format=csv 2>&1
  nvidia-smi topo -m 2>&1
fi

echo "== modules (kernel $(uname -r))"
if [ -r "$DEST/SHA256SUMS" ]; then src=$DEST; elif [ -n "$OUT" ]; then src=$OUT; else die "not installed in $DEST and OUT is not set"; fi
load_pins "$src"
for m in "${MODS[@]}"; do
  f=$src/$m.ko
  [ "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" = "${SHA[$m]}" ] || fail "$f does not match SHA256SUMS"
  [ "$m" = nvidia-peermem ] && continue
  l=$(cat "/sys/module/${m//-/_}/srcversion" 2>/dev/null)
  want "$m loaded from the patched build ($src)" "$m loaded: '${l:-not loaded}', not the srcversion of $f" \
    [ "$l" = "$(modinfo -F srcversion "$f")" ]
done
[ "$src" = "$DEST" ] && echo "modprobe resolves nvidia to $(modinfo -k "$KVER" -F filename nvidia)"
head -1 /proc/driver/nvidia/version

echo "== driver parameters"
P=/proc/driver/nvidia/params
grep -E '^(RegistryDwords|RegistryDwordsPerDevice|EnableResizableBar):' "$P"
pd=$(live_pd)
for g in $GPUS; do
  if e=$(card_ok "$pd" "$g"); then pass "per-device entry for $g (P2P_ENABLE='$P2P_ENABLE')"; else fail "$e"; fi
done
# shellcheck disable=SC2329  # called through want
no_global_key() { ! grep -q '^RegistryDwords:.*RMDynBar1P2PEnable' "$P"; }
want "no global RMDynBar1P2PEnable" "RegistryDwords sets RMDynBar1P2PEnable globally; use the per-device line" no_global_key
want "EnableResizableBar: 0" "EnableResizableBar is not 0" grep -qx 'EnableResizableBar: 0' "$P"
for c in "nvidia nv_dynbar1_calib 0" "nvidia nv_dynbar1_delta 0" "nvidia nv_hugetlb_pin_fast_path 0" \
         "nvidia_uvm uvm_disable_hmm Y" "nvidia_uvm uvm_bar1_gate_trips 0"; do
  read -r mod p exp <<<"$c"; v=$(param "$mod" "$p")
  want "$mod.$p=$v" "$mod.$p='$v' (want $exp)" [ "$v" = "$exp" ]
done
echo "counters: nvidia.nv_dynbar1_rm_p2p_refused=$(param nvidia nv_dynbar1_rm_p2p_refused)" \
  "nvidia_uvm.uvm_bar1_gate_pairs=$(param nvidia_uvm uvm_bar1_gate_pairs)"

echo "== GPUs"
for g in $GPUS; do
  drv=$(basename "$(readlink "/sys/bus/pci/devices/$g/driver" 2>/dev/null)" 2>/dev/null)
  read -r fbt bt < <(nvidia-smi -i "$g" -q -d MEMORY 2>/dev/null | awk '/FB Memory Usage/ { s = "fb"; next }
    /BAR1 Memory Usage/ { s = "bar"; next } s != "" && /Total/ { v[s] = $3; s = "" } END { print (v["fb"] == "" ? "?" : v["fb"]), (v["bar"] == "" ? "?" : v["bar"]) }')
  echo "$g driver ${drv:-none}, VRAM ${fbt:-?} MiB, BAR1 Total ${bt:-?} MiB, lspci $(lspci -vv -s "$g" 2>/dev/null | grep -m1 -o 'Region 1:.*' | grep -o 'size=[0-9A-Z]*')"
  want "$g bound to nvidia" "$g bound to '${drv:-none}'" [ "$drv" = nvidia ]
  want "$g BAR1 $bt MiB >= VRAM $fbt MiB" "$g BAR1 Total '$bt' MiB is not at least its VRAM '$fbt' MiB" ge "$bt" "$fbt"
done

# shellcheck disable=SC2086  # GPUS is a list of addresses
show_pairs "$pd" $GPUS
for g in $GPUS; do
  chip_check "$g"
  case $C_CLASS in verified | default | opt-in) ;; *) fail "$g: ${C_CHIP:-unknown chip} ($C_CLASS${C_WHY:+: $C_WHY}) is not a card for this driver's P2P; remove it from GPUS" ;; esac
done

echo "== P2P (nvidia-smi topo)"
declare -A IDX=()
while IFS=', ' read -r i b; do
  b=${b,,}; [ "${#b}" -le 12 ] || b=${b: -12}
  IDX[$b]=$i
done < <(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null)
# topo_cell <matrix> <row index> <column index>: the cell, from the matrix rows only (the header row also starts with
# GPU0).
# shellcheck disable=SC2016
topo_cell() { awk -v r="GPU$2" -v c="$3" '$1 == r && $2 !~ /^GPU/ { print $(c + 2); exit }' <<<"$1"; }
for k in r w; do
  t=$(nvidia-smi topo -p2p "$k" 2>&1); printf '%s\n' "$t"
  # shellcheck disable=SC2086  # GPUS is a list of addresses
  while read -r a b; do
    c=; [ -z "${IDX[$a]:-}" ] || [ -z "${IDX[$b]:-}" ] || c=$(topo_cell "$t" "${IDX[$a]}" "${IDX[$b]}")
    s=${VSTATE["$a $b"]}
    case $s in
      verified | default | opted-in) want "topo -p2p $k $a <-> $b: OK" "topo -p2p $k $a <-> $b: '${c:-?}' although the pair is $s" [ "$c" = OK ] ;;
      untested | off) want "topo -p2p $k $a <-> $b: ${c:-?} (P2P off, as the pair is $s)" "topo -p2p $k $a <-> $b: OK although the pair is $s" [ "$c" != OK ] ;;
      *) echo "topo -p2p $k $a <-> $b: ${c:-?} (pair $s: no expectation)" ;;
    esac
  done < <(pairs $GPUS)
done

echo "== kernel log this boot"
k=$(dmesg 2>/dev/null)
for pair in "Xid|NVRM:.*Xid" "AER|AER:.*(Corrected|Uncorrected|Fatal)" "DMAR|DMAR: \[DMA|DMAR:.*fault" "init failures|RmInitAdapter"; do
  n=$(grep -cE "${pair#*|}" <<<"$k")
  if [ "$n" = 0 ]; then pass "${pair%%|*} lines: 0"; else fail "${pair%%|*} lines: $n"; grep -E "${pair#*|}" <<<"$k" | tail -3; fi
done
echo "DynBar1P2P refusal lines: $(grep -c 'DynBar1P2P:' <<<"$k")"; grep 'DynBar1P2P:' <<<"$k" | tail -3
echo "unixCallVideoBIOS 'vesa call failed' lines: $(grep -c 'vesa call failed' <<<"$k") (benign, logged at nvidia_drm unload)"

if [ "$MODE" = integrity ]; then
  echo "== integrity (byte-exact peer copies both ways, then bandwidth; copies up to $MAXMIB MiB)"
  bin=$HERE/integrity/p2p-integrity
  if [ ! -x "$bin" ] || [ "$HERE/integrity/p2p-integrity.cu" -nt "$bin" ]; then
    "$HERE/integrity/build.sh" "$bin" || { bin=; fail "cannot build $HERE/integrity/p2p-integrity (above)"; }
  fi
  # Limits: the whole run and each transfer, so a hung peer transfer ends in a FAIL line instead of a hang. Both
  # grow with the size (a transfer of --max-mib over a slow peer-read path needs more than a fixed limit).
  # INTEGRITY_TIMEOUT (seconds, default 1200 + MAXMIB/2) and INTEGRITY_OP_TIMEOUT (default 120 + MAXMIB/64) override.
  itime=${INTEGRITY_TIMEOUT:-$((1200 + MAXMIB / 2))} otime=${INTEGRITY_OP_TIMEOUT:-$((120 + MAXMIB / 64))}
  [[ $itime =~ ^[1-9][0-9]*$ && $otime =~ ^[1-9][0-9]*$ ]] || die "INTEGRITY_TIMEOUT and INTEGRITY_OP_TIMEOUT must be whole seconds"
  command -v timeout >/dev/null || die "timeout (coreutils) is needed for --integrity"
  grace=$((itime / 10 > 5 ? itime / 10 : 5))
  passed=() out=$(mktemp) || die "mktemp failed"
  # a PASS is recorded only when the check above is clean (this build loaded, its options and parameters, topo),
  # and names the loaded build, so p2p-enable.sh can refuse a PASS from another driver.
  checked_fails=$FAILS nvsrc=$(srcv) nvver=$(cat /sys/module/nvidia/version 2>/dev/null)
  # shellcheck disable=SC2086  # GPUS is a list of addresses
  [ -z "$bin" ] || while read -r a b; do
    s=${VSTATE["$a $b"]}
    case $s in stock | unsupported) echo "SKIP $a <-> $b: not tested (the pair is $s)"; continue ;; esac
    ev0=$(events "$a" "$b")
    # the test sees only this pair (CUDA_VISIBLE_DEVICES by UUID; the UUIDs are never printed, the report stays
    # free of them), so CUDA does not query, and the driver does not refuse, pairs with other GPUs in the machine.
    ua=$(nvidia-smi --query-gpu=uuid --format=csv,noheader -i "$a" 2>/dev/null) ub=$(nvidia-smi --query-gpu=uuid --format=csv,noheader -i "$b" 2>/dev/null)
    if [[ $ua =~ ^GPU-[0-9a-f-]+$ && $ub =~ ^GPU-[0-9a-f-]+$ ]]; then vis="$ua,$ub" visn="only these two cards"
    else vis='' visn="every GPU (could not read the UUIDs of the pair from nvidia-smi)"; fi
    echo "-- $a <-> $b (pair $s): $bin --pair $a $b --max-mib $MAXMIB --timeout $itime --op-timeout $otime; CUDA sees $visn"
    if [ -n "$vis" ]; then export CUDA_VISIBLE_DEVICES=$vis; else unset CUDA_VISIBLE_DEVICES; fi
    timeout -k 10 $((itime + grace)) "$bin" --pair "$a" "$b" --max-mib "$MAXMIB" --timeout "$itime" --op-timeout "$otime" \
      2>&1 </dev/null | tee "$out" | sed 's/^/  /'
    rc=${PIPESTATUS[0]} ev1=$(events "$a" "$b")
    unset CUDA_VISIBLE_DEVICES
    # the size and number of cases that ran, from the test's own last line
    mm='' nc=''; read -r mm nc < <(sed -n "s/^RESULT PASS $a $b max-mib \([0-9]*\) cases \([0-9]*\) .*/\1 \2/p" "$out" | tail -1)
    case $rc in
      0)
        if [ -z "${nc:-}" ] || [ "$nc" = 0 ]; then
          fail "integrity $a <-> $b: exit status 0 but no 'RESULT PASS ... cases N' line with N > 0"
        elif [ "$ev0" = "$ev1" ]; then
          pass "integrity $a <-> $b (max-mib $mm, $nc cases)"; passed+=("$a" "$b")
          if [ "$checked_fails" != 0 ]; then
            echo "note: PASS not recorded for p2p-enable.sh: the check above has $checked_fails FAIL line(s)"
          else
            mkdir -p "$STATE_DIR" && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) PASS $a $(card_ids "$a") $b $(card_ids "$b") nvidia ${nvsrc:-?} version ${nvver:-?} max-mib $mm cases $nc" >>"$PASS_FILE"
            [ "$mm" -ge "$GATE_MAXMIB" ] && [ "$nc" -ge "$GATE_CASES" ] ||
              echo "note: a run below --max-mib $GATE_MAXMIB ($GATE_CASES cases) does not count for p2p-enable.sh"
          fi
        else
          fail "integrity $a <-> $b: copies clean, but the kernel log has new events (before: $ev0; after: $ev1)"
        fi ;;
      3)
        if [ "$s" = untested ] || [ "$s" = off ]; then
          echo "NOT RUN $a <-> $b: no peer access (the pair is $s). Trial load with the key, nothing persisted:" \
            "sudo env P2P_ENABLE=1 $HERE/p2p-load.sh --yes, then run --integrity again"
        else
          fail "integrity $a <-> $b: no peer access although the pair is $s"
        fi ;;
      4 | 124 | 137)
        fail "integrity $a <-> $b: timed out (hung peer transfer?; limits ${itime} s for the run, ${otime} s per transfer)"
        echo "kernel log, last lines:"; dmesg 2>/dev/null | tail -20 | sed 's/^/  /'
        echo "STOPPED after the timeout: the GPUs may be wedged, so no further pair is tested. Reboot before testing again."
        break ;;
      *) fail "integrity $a <-> $b (p2p-integrity exit status $rc)" ;;
    esac
  done < <(pairs $GPUS)
  rm -f "$out"
  echo "== report"
  echo "This output is in $P2P_REPORT. Please attach it to a compatibility report: $REPORT_URL"
  echo "It has no serial numbers or GPU UUIDs; check paths and names in it before posting."
  need=
  for g in $(printf '%s\n' "${passed[@]}" | sort -u); do
    chip_check "$g"
    boot=$(boot_pd)
    if { [ "$C_CLASS" = opt-in ] && [ "$(card_key "$boot" "$g" RMDynBar1P2PEnable)" != 1 ]; } ||
      [ "$(card_key "$boot" "$g" RMForceStaticBar1)" != 0 ]; then need+=" $g"; fi
  done
  [ -z "$need" ] || echo "To keep P2P on for these cards from the next boot (RMDynBar1P2PEnable=1 for opt-in chips," \
    "driver_option=on where geforce-bar1-resize keeps static BAR1): sudo $HERE/p2p-enable.sh --yes$need"
fi

if [ "$FAILS" = 0 ]; then echo "ALL PASS"; else echo "$FAILS FAIL line(s). Back to stock: $HERE/p2p-fallback.sh --yes --live"; fi
exit "$FAILS"
