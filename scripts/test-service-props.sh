#!/usr/bin/env bash
# Ad-hoc smoke test for the service.sh ROM-hook/residue block (v3.0.14).
# Extracts the block and runs it against a stubbed resetprop that keeps an
# in-memory store (persistent/ram are folded into one; the block must end
# with the family absent in BOTH on non-hook ROMs, and present with the
# upstream neutralization values on hook ROMs).
set -u
cd "$(dirname "$0")/.."
PASS=0 FAIL=0
GJSON=/tmp/test-gms-certified.json
export AEGIS_GMS_JSON="$GJSON"
ok() { if [ "$2" = "1" ]; then PASS=$((PASS+1)); echo "  ok - $1"; else FAIL=$((FAIL+1)); echo "  FAIL - $1"; fi }

BLOCK=$(awk '/^# ---------- ROM pixel-imitation hooks/,/^resetprop -c >\/dev\/null/' module/service.sh)
[ -n "$BLOCK" ] && ok "block extracted from service.sh" 1 || ok "block extracted from service.sh" 0

# --- resetprop stub: one store; args like the real tool for the subset used ---
STORE=/tmp/service-props-store.txt
: > "$STORE"
resetprop() {
    if [ $# -eq 0 ]; then cut -d= -f1 "$STORE" 2>/dev/null; return 0; fi
    while [ $# -gt 0 ]; do
        case "$1" in
            -n) ;;
            -p) ;;
            -Z) return 1 ;;
            -c) return 0 ;;
            --delete)
                grep -v "^$2=" "$STORE" > "$STORE.t" 2>/dev/null; mv "$STORE.t" "$STORE"; return 0 ;;
            *) break ;;
        esac
        shift
    done
    if [ $# -eq 1 ]; then
        if grep -q "^$1=" "$STORE"; then
            grep -m1 "^$1=" "$STORE" | cut -d= -f2-; return 0
        fi
        return 1
    fi
    if [ $# -eq 2 ]; then
        grep -v "^$1=" "$STORE" > "$STORE.t" 2>/dev/null; mv "$STORE.t" "$STORE"
        echo "$1=$2" >> "$STORE"; return 0
    fi
    return 0
}
resetprop_if_diff() {
    local cur; cur="$(resetprop "$1" 2>/dev/null)"
    [ -z "$cur" ] || [ "$cur" = "$2" ] && return 0
    resetprop "$1" "$2"; return 0
}
dbg() { echo "dbg: $*" >> /tmp/service-props-dbg.txt; return 0; }
getprop() { [ "$1" = "ro.product.vendor.name" ] && { echo "miui"; return; }; return 1; }

seed() { : > "$STORE"; for kv in "$@"; do echo "$kv" >> "$STORE"; done; }

ALL="persist.sys.pihooks.first_api_level persist.sys.pihooks.security_patch
persist.sys.pihooks.disable.gms_props persist.sys.pihooks.disable.gms_key_attestation_block
persist.sys.entryhooks_enabled persist.sys.pixelprops.gms persist.sys.pixelprops.gapps
persist.sys.pixelprops.google persist.sys.pixelprops.pi persist.sys.pp.gms
persist.sys.pp.vending persist.sys.spoof.gms"

# --- case A: K70-like, residue only (all values empty/false), no hook ROM ---
seed "persist.sys.pihooks.first_api_level=" "persist.sys.pixelprops.gms=false" \
      "persist.sys.pixelprops.gapps=false" "persist.sys.pixelprops.google=false" \
      "persist.sys.pixelprops.pi=false" "persist.sys.spoof.gms=false"
rm -f /data/system/gms_certified_props.json 2>/dev/null
eval "$BLOCK"
left=0; for p in $ALL; do resetprop "$p" >/dev/null 2>&1 && left=$((left+1)); done
[ "$left" = 0 ] && ok "caseA: all 12 residue props deleted on non-hook ROM" 1 || ok "caseA: all 12 residue props deleted on non-hook ROM (left=$left)" 0
grep -q "cleaned" /tmp/service-props-dbg.txt && ok "caseA: cleanup logged" 1 || ok "caseA: cleanup logged" 0

# --- case B: idempotent second run on a clean device ---
rm -f /tmp/service-props-dbg.txt
eval "$BLOCK"
left=0; for p in $ALL; do resetprop "$p" >/dev/null 2>&1 && left=$((left+1)); done
[ "$left" = 0 ] && ok "caseB: clean device stays clean" 1 || ok "caseB: clean device stays clean (left=$left)" 0
[ -f /tmp/service-props-dbg.txt ] && ok "caseB: no cleanup log churn when nothing to do" 0 || ok "caseB: no cleanup log churn when nothing to do" 1

# --- case C: genuine hook ROM (LeafOS json) -> upstream neutralization runs ---
seed "persist.sys.pixelprops.gms=true"
: > "$GJSON"
rm -f /tmp/service-props-dbg.txt
eval "$BLOCK"
[ "$(resetprop persist.sys.pixelprops.gms 2>/dev/null)" = "false" ] \
    && ok "caseC: hook ROM gets pixelprops.gms=false (upstream neutralization)" 1 \
    || ok "caseC: hook ROM gets pixelprops.gms=false (upstream neutralization)" 0
[ "$(resetprop persist.sys.spoof.gms 2>/dev/null)" = "false" ] \
    && ok "caseC: hook ROM gets spoof.gms=false (LeafOS path)" 1 \
    || ok "caseC: hook ROM gets spoof.gms=false (LeafOS path)" 0
rm -f /data/system/gms_certified_props.json

# --- case D: ROM-authored non-empty pihooks value counts as hook evidence ---
seed "persist.sys.pihooks.first_api_level=33" "persist.sys.pixelprops.gms=true"
rm -f "$GJSON"
eval "$BLOCK"
[ "$(resetprop persist.sys.pixelprops.gms 2>/dev/null)" = "false" ] \
    && ok "caseD: ROM-authored pihooks value -> neutralization, not deletion" 1 \
    || ok "caseD: ROM-authored pihooks value -> neutralization, not deletion" 0

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
