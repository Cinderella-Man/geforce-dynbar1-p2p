#!/bin/bash
# Turn dynamic BAR1 P2P on from the next boot for each card given, through geforce-bar1-resize's per-card entry in
# /etc/geforce-bar1-resize.conf (its documented keys, docs/configuration.md and docs/driver-option.md; no second
# modprobe.d file), then `geforce-bar1-resize driver-option --write`, which writes zz-geforce-bar1-resize.conf. The
# driver reads it at the next load of nvidia (reboot; p2p-install.sh must be in place for the patched build).
# - Opt-in chips (p2p-check.sh --pairs): keys= gets RMDynBar1P2PEnable=1. GA102 is on by default and gets no key.
# - Any card without RMForceStaticBar1=0 in what modprobe reads (geforce-bar1-resize sets it by default only for cards
#   it enlarges through 0x610; a card that only needed a resize, or whose BAR1 was already large, keeps static BAR1):
#   driver_option=on, which dynamic BAR1 P2P needs. GeForce Blackwell stays stock (static BAR1, NVIDIA's own P2P).
# - Each card needs an --integrity PASS recorded for it (address and ids) in /var/lib/geforce-dynbar1-p2p/integrity-pass;
#   --skip-integrity enables without one, at your own risk.
# - --undo removes RMDynBar1P2PEnable from the card's keys= again: back to the default, off for opt-in chips. A
#   driver_option=on stays (it only keeps VRAM fully host-visible); remove it from the entry by hand if you want.
# - The card's entry: the CARD[] entry geforce-bar1-resize uses for it now (the address entry if its ids= match, else
#   vendor:device/subvendor:subdevice, else vendor:device) becomes an address entry with ids= (so a different card that
#   later sits at that address is not touched), its other settings kept. An existing one-line address entry is replaced
#   in place; a new one goes into the `declare -A CARD=(` block, or at the end of the file, as geforce-bar1-resize's
#   install.sh does. The old config is backed up to /var/backups/geforce-dynbar1-p2p/<time>/.
# Usage: p2p-enable.sh --dry-run | --yes [--undo] [--skip-integrity] ADDRESS...
set -u
export LC_ALL=C
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
KEY=RMDynBar1P2PEnable
flags=() cards=()
for a in "$@"; do case $a in --*) flags+=("$a") ;; *) cards+=("$a") ;; esac; done
parse_args "--undo --skip-integrity" "${flags[@]}"
[ ${#cards[@]} -gt 0 ] || { echo "usage: $0 --dry-run | --yes [--undo] [--skip-integrity] ADDRESS..."; exit 2; }
UNDO=0; has_flag --undo && UNDO=1
BACKUP_P2P=/var/backups/geforce-dynbar1-p2p
# geforce-bar1-resize's option file (docs/driver-option.md); restored with the config if the change is rolled back
GBR_OPT_FILE=${GBR_OPT_FILE:-/etc/modprobe.d/zz-geforce-bar1-resize.conf}
# Cards this script gave RMDynBar1P2PEnable=1, "<address> <ids>" per line: --undo removes only those keys.
ENABLED_FILE=$STATE_DIR/enabled

# entry_of <config> <address> <ids>: "<CARD key><TAB><value>" of the entry geforce-bar1-resize uses for the card, or
# nothing. Same order as its card_cfg: address (when its ids= match), then vendor:device/sub, then vendor:device.
entry_of() {
  # shellcheck disable=SC2016  # expanded by the inner bash
  bash -c '
    declare -A CARD=()
    . "$1" >/dev/null 2>&1
    b=$2 ids=$3 want=""
    if [ -n "${CARD[$b]+x}" ]; then
      for w in ${CARD[$b]}; do [[ $w != ids=* ]] || want=${w#ids=}; done
      want=${want,,}
      if [ -z "$want" ] || [ "$want" = "$ids" ] || [ "$want" = "${ids%%/*}" ]; then printf "%s\t%s\n" "$b" "${CARD[$b]}"; exit 0; fi
    fi
    for k in "$ids" "${ids%%/*}"; do
      if [ -n "${CARD[$k]+x}" ]; then printf "%s\t%s\n" "$k" "${CARD[$k]}"; exit 0; fi
    done
  ' _ "$1" "$2" "$3"
}
# merged <value> <ids> <key: set|unset|undo> <driver_option 0|1>: the address entry: ids=, the other words of the
# value, driver_option=on when asked, and keys= with RMDynBar1P2PEnable: set = every value replaced by
# RMDynBar1P2PEnable=1 at the end; unset = every value removed (GA102: on by default); undo = only RMDynBar1P2PEnable=1
# removed (a user's =0 stays).
merged() {
  local w out="ids=$2" keys="" nk="" t toks words
  read -r -a words <<<"$1"
  for w in "${words[@]}"; do
    case $w in
      keys=*) keys=${w#keys=} ;;
      ids=*) ;;
      driver_option=*) [ "$4" = 1 ] || out+=" $w" ;;
      *) out+=" $w" ;;
    esac
  done
  [ "$4" != 1 ] || out+=" driver_option=on"
  IFS=';' read -r -a toks <<<"$keys"
  for t in "${toks[@]}"; do
    [ -n "$t" ] || continue
    case $3 in undo) [ "$t" = "$KEY=1" ] && continue ;; *) [[ $t == "$KEY="* ]] && continue ;; esac
    nk+="$t;"
  done
  [ "$3" != set ] || nk+="$KEY=1;"
  echo "$out${nk:+ keys=$nk}"
}
# keys_of <value>: its keys= list with a leading ';' (empty when none).
keys_of() { local w words; read -r -a words <<<"$1"; for w in "${words[@]}"; do [[ $w != keys=* ]] || echo ";${w#keys=}"; done; }
# tracked <address> <ids>: p2p-enable.sh set RMDynBar1P2PEnable=1 for this card (ENABLED_FILE).
tracked() { grep -qxF "$1 $2" "$ENABLED_FILE" 2>/dev/null; }
# one_line <count> <regex>: the address entry is a single line CARD[a]="..." or [a]="..." (count = matching lines).
one_line() { [ "$1" = 1 ] && grep -qE "$2\"[^\"]*\"[[:space:]]*\$" "$TMP/conf"; }
# pass_for <address> <ids>: PASS_FILE has a full-size integrity PASS for the card (any partner) made with the nvidia
# build that will boot (srcversion BOOT_SRC).
pass_for() {
  awk -v g="$1" -v i="$2" -v mm="$GATE_MAXMIB" -v mc="$GATE_CASES" -v sv="$BOOT_SRC" '
    $2 != "PASS" || !(($3 == g && $4 == i) || ($5 == g && $6 == i)) { next }
    { m = 0; c = 0; s = ""; for (k = 7; k < NF; k++) { if ($k == "max-mib") m = $(k + 1); if ($k == "cases") c = $(k + 1); if ($k == "nvidia") s = $(k + 1) } }
    m + 0 >= mm && c + 0 >= mc && s == sv { f = 1 }
    END { exit !f }' "$PASS_FILE" 2>/dev/null
}

echo "== preflight (read-only)"
[ "$(id -u)" = 0 ] || die "must run as root"
GBR=$(command -v geforce-bar1-resize || echo /usr/local/sbin/geforce-bar1-resize)
[ -x "$GBR" ] || die "geforce-bar1-resize is not installed; it writes the per-card driver options (README, Requirements)"
[ -f "$GBR_CONF" ] || die "$GBR_CONF missing (geforce-bar1-resize's install.sh writes it)"
bash -n "$GBR_CONF" || die "$GBR_CONF has a syntax error"
boot=$(boot_pd)
# The nvidia build that boots: the boot install (p2p-install.sh), else the build in OUT that it will install.
BOOT_SRC='' BOOT_FROM=''
if [ "$UNDO" = 0 ] && ! has_flag --skip-integrity; then
  if [ -d "$DEST" ] && f=$(ko_in "$DEST" nvidia) && [ -n "$f" ]; then BOOT_FROM=$f
  elif [ -n "$OUT" ] && [ -f "$OUT/nvidia.ko" ]; then BOOT_FROM=$OUT/nvidia.ko
  else die "cannot tell which nvidia build will boot: no boot install in $DEST and OUT is not set in $CONFIG"
  fi
  BOOT_SRC=$(modinfo -F srcversion "$BOOT_FROM") && [ -n "$BOOT_SRC" ] || die "no srcversion in $BOOT_FROM"
  echo "build that boots: $BOOT_FROM (srcversion $BOOT_SRC); only an integrity PASS made with it counts"
fi
TMP=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
cp "$GBR_CONF" "$TMP/conf"
todo=()
declare -A AK=() DOPT=()
for g in "${cards[@]}"; do
  valid_bdf "$g" || die "'$g' is not $BDF_FORM; nothing written"
  [ -e "/sys/bus/pci/devices/$g" ] || die "no PCI device $g"
  chip_check "$g"
  case $C_CLASS in
    opt-in) AK[$g]=1 ;;
    verified | default) AK[$g]=0 ;;
    stock) die "$g: $C_CHIP is GeForce Blackwell; NVIDIA's own driver offers its BAR1 P2P (static BAR1), leave it stock" ;;
    datacenter) die "$g: $C_CHIP is a datacenter chip, not a target of this driver patch" ;;
    *) die "$g: unknown chip ($C_WHY)" ;;
  esac
  DOPT[$g]=0
  [ "$UNDO" = 1 ] || [ "$(card_key "$boot" "$g" RMForceStaticBar1)" = 0 ] || DOPT[$g]=1
  offv=$(card_key "$boot" "$g" "$KEY")
  if [ "${AK[$g]}${DOPT[$g]}" = 00 ] && [ "$UNDO" = 0 ]; then
    if [ -z "$offv" ] || [ "$offv" = 1 ]; then
      echo "$g: $C_CHIP, P2P on by default and RMForceStaticBar1=0 already set; nothing to do"; continue
    fi
    echo "$g: $C_CHIP is turned off ($KEY=$offv at the next load); enabling removes that key from its entry"
    # a key added by hand to the option file is not in keys=, so a changed entry cannot remove it
    ent=$(entry_of "$TMP/conf" "$g" "$C_IDS"); old=${ent#*$'\t'}; [ -n "$ent" ] || old=""
    [[ $(keys_of "$old") == *";$KEY=$offv;"* ]] ||
      die "$g: $KEY=$offv was added by hand to $GBR_OPT_FILE (it is not in keys= of the card's entry in $GBR_CONF); remove it there (geforce-bar1-resize keeps keys added by hand), then run p2p-enable.sh again"
  fi
  if [ "$UNDO" = 0 ] && bar=$(bar1_mib "$g") && vr=$(vram_mib "$g") && [ -n "$vr" ] && [ "$bar" -lt "$vr" ]; then
    die "$g: BAR1 $bar MiB is smaller than its $vr MiB of VRAM; geforce-bar1-resize has to enlarge it first"
  fi
  if [ "$UNDO" = 0 ] && ! has_flag --skip-integrity && ! pass_for "$g" "$C_IDS"; then
    die "$g ($C_CHIP, $C_IDS): no full --integrity PASS recorded in $PASS_FILE (needed: --max-mib $GATE_MAXMIB or more,
  at least $GATE_CASES cases, made with the nvidia build that boots, srcversion $BOOT_SRC; a shorter run or another
  build does not count). Trial load with the key (nothing persisted):
  sudo env P2P_ENABLE=1 $HERE/p2p-load.sh --yes
then: sudo $HERE/p2p-check.sh --integrity   (README, Opt-in). --skip-integrity enables without it, at your own risk."
  fi
  ent=$(entry_of "$TMP/conf" "$g" "$C_IDS")
  old=${ent#*$'\t'}; [ -n "$ent" ] || old=""
  if [ "$UNDO" = 1 ]; then new=$(merged "$old" "$C_IDS" undo 0)
  elif [ "${AK[$g]}" = 1 ]; then new=$(merged "$old" "$C_IDS" set "${DOPT[$g]}")
  else new=$(merged "$old" "$C_IDS" unset "${DOPT[$g]}"); fi
  if [ -n "$ent" ]; then echo "$g: $C_CHIP ($C_IDS); entry now: CARD[${ent%%$'\t'*}]=\"$old\""; else echo "$g: $C_CHIP ($C_IDS); no CARD[] entry yet"; fi
  [ "${DOPT[$g]}" = 0 ] || echo "$g: static BAR1 at the next load (no RMForceStaticBar1=0; geforce-bar1-resize sets it by default only for cards it enlarges through 0x610): add driver_option=on"
  if [ "$UNDO" = 1 ]; then
    if [[ $(keys_of "$old") != *";$KEY=1;"* ]]; then
      [ "$offv" != 1 ] || die "$g: $KEY=1 was added by hand to $GBR_OPT_FILE (it is not in keys= of the card's entry in $GBR_CONF); remove it there (geforce-bar1-resize keeps keys added by hand)"
      echo "$g: no $KEY=1 in its entry, nothing to undo"; continue
    fi
    # a shared entry (vendor:device[/subsystem]) applies to every card with these ids; it is not this script's
    [ "${ent%%$'\t'*}" = "$g" ] || die "$g: $KEY=1 comes from the shared entry CARD[${ent%%$'\t'*}] in $GBR_CONF, which applies to every card with these ids and which p2p-enable.sh never writes; remove the key there by hand (or give $g its own CARD[$g] entry)"
    tracked "$g" "$C_IDS" || die "$g: $KEY=1 in CARD[${ent%%$'\t'*}] was not set by p2p-enable.sh (not in $ENABLED_FILE); remove it there by hand"
  fi
  [ "$UNDO" = 0 ] || [[ $new != *driver_option=on* ]] || echo "$g: driver_option=on stays (remove it from the entry by hand for static BAR1)"
  re="^[[:space:]]*(CARD)?\\[${g//./\\.}\\]="
  n=$(grep -cE "$re" "$TMP/conf")
  if [ "$UNDO" = 1 ] && [ "$new" = "ids=$C_IDS" ]; then
    [ "$n" = 0 ] && die "internal: no address entry for $g although its entry is CARD[$g]"
    one_line "$n" "$re" || die "CARD[$g] in $GBR_CONF spans several lines or is set more than once; remove $KEY from its keys= by hand"
    awk -v re="$re" '$0 !~ re' "$TMP/conf" >"$TMP/new" && mv "$TMP/new" "$TMP/conf"
    echo "$g: remove its address entry (only ids= would be left)"
  elif [ "$n" = 0 ]; then
    if grep -q '^declare -A CARD=($' "$TMP/conf"; then
      awk -v l="  [$g]=\"$new\"" '{ print } !d && $0 == "declare -A CARD=(" { print l; d = 1 }' "$TMP/conf" >"$TMP/new"
    else
      { cat "$TMP/conf"; printf 'CARD[%s]="%s"\n' "$g" "$new"; } >"$TMP/new"
    fi
    mv "$TMP/new" "$TMP/conf"
    echo "$g: add CARD[$g]=\"$new\""
  else
    one_line "$n" "$re" || die "CARD[$g] in $GBR_CONF spans several lines or is set more than once; edit its keys= by hand (README, Opt-in)"
    awk -v re="$re" -v new="$new" '$0 ~ re { match($0, /^[[:space:]]*(CARD)?\[[^]]*\]=/); print substr($0, 1, RLENGTH) "\"" new "\""; next } { print }' \
      "$TMP/conf" >"$TMP/new" && mv "$TMP/new" "$TMP/conf"
    echo "$g: set CARD[$g]=\"$new\""
  fi
  ent=$(entry_of "$TMP/conf" "$g" "$C_IDS")
  v=$(card_key "pci=$g;${ent#*keys=}" "$g" "$KEY"); [[ $ent == *keys=* ]] || v=
  if [ "$UNDO" = 1 ]; then [ "$v" != 1 ] || die "internal: $KEY=1 still set for $g in the new config"
  elif [ "${AK[$g]}" = 0 ]; then [ -z "$v" ] || die "internal: $KEY still set for $g in the new config"
  else [ "$v" = 1 ] || die "internal: the new config does not give $g $KEY=1"
  fi
  [ "${DOPT[$g]}" = 0 ] || [[ " ${ent#*$'\t'} " == *" driver_option=on "* ]] || die "internal: the new config does not give $g driver_option=on"
  todo+=("$g")
done
[ ${#todo[@]} -gt 0 ] || { echo "nothing to change"; exit 0; }
bash -n "$TMP/conf" || die "internal: the new config has a syntax error; nothing written"
echo "== change to $GBR_CONF"
diff -u "$GBR_CONF" "$TMP/conf" | tail -n +3

# applied <per-device string> <where>: every card in todo gets what it should there; prints one line per card.
applied() {
  local g v want ok=0
  for g in "${todo[@]}"; do
    v=$(card_key "$1" "$g" "$KEY")
    if [ "$UNDO" = 1 ]; then
      if [ "$v" != 1 ]; then echo "$g: $KEY ${v:-unset} $2"; else echo "$g: $KEY is still 1 $2"; ok=1; fi
      continue
    fi
    if [ "${AK[$g]}" = 0 ]; then want=""; else want=1; fi
    if [ "$v" = "$want" ]; then echo "$g: $KEY ${v:-unset} $2"
    else echo "$g: $KEY is '${v:-unset}' $2, want '${want:-unset}'"; ok=1
    fi
    [ "$UNDO" = 1 ] && continue
    if [ "$(card_key "$1" "$g" RMForceStaticBar1)" = 0 ]; then echo "$g: RMForceStaticBar1=0 $2"
    else echo "$g: no RMForceStaticBar1=0 $2 (static BAR1 stays; dynamic BAR1 P2P needs it)"; ok=1
    fi
  done
  return $ok
}

# What geforce-bar1-resize would write from the new config (driver-option --print writes nothing). A card outside its
# scope (CARDS, EXCLUDE, enable=no, route=skip), or a foreign per-device line, shows here, before anything changes.
echo "== preview: GBR_CONF=<new config> $GBR driver-option --print"
pv=$(GBR_CONF="$TMP/conf" "$GBR" driver-option --print 2>&1) || die "not applied: driver-option --print failed; nothing written:
$pv"
# its own line is the 'options nvidia' line; a foreign per-device line elsewhere in modprobe.d is reported after
# it, and --write would refuse it.
fl=$(grep 'foreign NVreg_RegistryDwordsPerDevice line in ' <<<"$pv" | head -n 1)
[ -z "$fl" ] || die "not applied: ${fl#*foreign }; geforce-bar1-resize --write stops on it (see its docs/driver-option.md, --adopt-driver-line); nothing written"
applied "$(grep -E '^options nvidia ' <<<"$pv" | grep -o 'NVreg_RegistryDwordsPerDevice=[^ ]*' | tail -n 1)" "in the preview" ||
  die "not applied: geforce-bar1-resize would not write this (card outside its scope: CARDS, EXCLUDE, enable=no or route=skip in $GBR_CONF?); nothing written"
if [ "$DRY" = 1 ]; then echo "+ $GBR driver-option --write"; echo "(dry run: nothing changed; end of plan)"; exit 0; fi

echo "== write"
mkdir -p "$BACKUP_P2P" || die "cannot create $BACKUP_P2P"
BK=$(mktemp -d "$BACKUP_P2P/$(date +%Y%m%d-%H%M%S).XXXX") || die "cannot create a backup directory in $BACKUP_P2P"
cp -a "$GBR_CONF" "$BK/" || die "cannot back up $GBR_CONF"
if [ -e "$GBR_OPT_FILE" ]; then cp -a "$GBR_OPT_FILE" "$BK/" || die "cannot back up $GBR_OPT_FILE"; fi
echo "backup: $BK"
# rollback <why>: the config and the option file as they were, then stop. Each restore is checked against its copy.
rollback() {
  local bad='' cbk=$BK/${GBR_CONF##*/} obk=$BK/${GBR_OPT_FILE##*/}
  if ! { cp -a "$cbk" "$GBR_CONF" && cmp -s "$cbk" "$GBR_CONF"; }; then bad+=" $GBR_CONF (copy: $cbk)"; fi
  if [ -e "$obk" ]; then
    if ! { cp -a "$obk" "$GBR_OPT_FILE" && cmp -s "$obk" "$GBR_OPT_FILE"; }; then bad+=" $GBR_OPT_FILE (copy: $obk)"; fi
  else
    rm -f "$GBR_OPT_FILE"; [ ! -e "$GBR_OPT_FILE" ] || bad+=" $GBR_OPT_FILE (did not exist before; remove it)"
  fi
  [ -z "$bad" ] || die "$1; ROLLBACK FAILED for:$bad. Restore by hand, then check with: $GBR driver-option --print"
  die "$1; rolled back: $GBR_CONF and $GBR_OPT_FILE are as before (copies in $BK)"
}
cat "$TMP/conf" >"$GBR_CONF" || rollback "cannot write $GBR_CONF"
run "$GBR" driver-option --write || rollback "driver-option --write failed"

echo "== verify"
applied "$(boot_pd)" "at the next load of nvidia" || rollback "not applied in the per-device line modprobe reads"
# remember which cards got RMDynBar1P2PEnable=1 from this script; --undo removes only those.
mkdir -p "$STATE_DIR" || echo "warning: cannot create $STATE_DIR"
for g in "${todo[@]}"; do
  ids=$(card_ids "$g")
  if [ "$UNDO" = 1 ]; then
    { grep -vxF "$g $ids" "$ENABLED_FILE" 2>/dev/null || true; } >"$TMP/enabled" && cat "$TMP/enabled" >"$ENABLED_FILE"
  elif [ "${AK[$g]}" = 1 ] && ! tracked "$g" "$ids"; then
    echo "$g $ids" >>"$ENABLED_FILE"
  fi
done
echo "DONE; backup in $BK. The running driver is unchanged: reboot (with p2p-install.sh in place), then run" \
  "$HERE/p2p-check.sh"
