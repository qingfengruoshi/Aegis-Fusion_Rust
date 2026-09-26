#!/usr/bin/env bash
# test-mask-ids.sh — the device-id mask has FOUR copies and they must agree,
# and must not be coupled to one upstream spelling (audit r5).
#
#   module/customize.sh        install-time, rewrites old log shards in place
#   module/engine-check.sh     mask_ids(), terminal output pasted into reports
#   module/engine-verdict.sh   mask_ids(), same output surface (audit N13)
#   module/webroot/js/logs.js  maskDeviceIds(), the /sdcard/Download export
#                              (covered by scripts/test-logs.js — it needs a DOM,
#                               so it cannot be exercised from here)
#
# Why this test exists: the export lands in /sdcard/Download, which any app with
# storage permission can read, so the mask is the only control between the
# harvested IMEI/MEID/serial and third-party apps. Until audit r5 the unquoted
# rule accepted only [A-Za-z0-9]{4,} immediately after '=', so a hyphenated
# value, a value whose first alphanumeric run was shorter than four, a
# space-separated value and the `serialno` key (the property the engine reads)
# all passed through untouched. A fix applied to one copy and not the others is
# the failure mode this suite is designed to catch.
set -u
cd "$(dirname "$0")/.."
PASS=0 FAIL=0
ok() { if [ "$2" = "1" ]; then PASS=$((PASS+1)); echo "  ok - $1"; else FAIL=$((FAIL+1)); echo "  FAIL - $1"; fi }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/af-mask.XXXXXX") || exit 1
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

SHELL_COPIES="module/customize.sh module/engine-check.sh module/engine-verdict.sh"

# Turn the extracted `-e "s/…"` lines into a plain sed -E program file, so the
# expressions are executed exactly as the module executes them (no eval, and no
# second implementation to drift out of sync).
extract_program() { # <sh-file> <out-program-file>
    awk '/^[[:space:]]*-e "s\//{ print }' "$1" \
        | sed -e 's/^[[:space:]]*-e "//' -e 's/"[[:space:]]*\\*[[:space:]]*$//' -e 's/\\"/"/g' \
        > "$2"
}

IDENT='350000000000001'
MEID='A0000000DEADBEEF'
SER='0123456789ABCDEF'
HYPH='SN-1234567'
PROBE='SHA-256:abcdef0123456789'

# Every shape the engine/diagnostics can carry. A = the form Harvester.kt prints
# today; B = the Kotlin toString() shape; C/D = JSON (audit N1); E = the property
# the engine reads; F = no separator at all; G = a value with a non-alphanumeric
# run; H is the NEGATIVE CONTROL - it must survive byte-for-byte, or the mask has
# started eating innocent log text.
cat > "$WORK/cases.txt" <<EOF
Harvest telephony IDs: imei='$IDENT' secondImei='' meid='$MEID' serial='$SER'
Record(harvestFailed=false, harvestedAt=1789116261073, imei=$IDENT, imei2=, meid=$MEID, serial=$HYPH)
{"harvest":{"imei":"$IDENT","meid":"$MEID","serial":"$SER"}}
"imei" : "$IDENT"  ,  "serial" : "$SER"
Harvest: device ids not supplied; ro.serialno=$HYPH
Harvest telephony IDs: imei $IDENT
control: pushed config (probe) meid=$PROBE
java.io.InvalidClassException: serialVersionUID mismatch
EOF

RESIDUE_RE="$IDENT|$MEID|$SER|$HYPH|$PROBE|abcdef0123456789"

echo "== mask copies: expression parity =="
# Each copy must carry the same four expressions. Compare the sorted expression
# sets, so a whitespace/order difference alone is not a failure but a missing or
# stale rule is.
REF=""
for f in $SHELL_COPIES; do
    n=$(awk '/^[[:space:]]*-e "s\//{ c++ } END{ print c+0 }' "$f")
    [ "$n" = "4" ] && ok "$f: 4 mask expressions" 1 || ok "$f: $n mask expressions (want 4 — r5 widening missing?)" 0
    extract_program "$f" "$WORK/prog.$$.$(basename "$f")"
    sig=$(sort "$WORK/prog.$$.$(basename "$f")" | tr -d '[:space:]')
    if [ -z "$REF" ]; then
        REF="$sig"
        ok "$f: reference copy captured" 1
    else
        [ "$sig" = "$REF" ] && ok "$f: expressions identical to the reference copy" 1 \
                            || ok "$f: expressions DIFFER from the reference copy (the four copies must agree)" 0
    fi
    # The two shells the module actually runs: the expressions must be the raw
    # ones, unquoted at the sed level (no leftover shell escaping).
    if grep -q '\\"' "$WORK/prog.$$.$(basename "$f")"; then
        ok "$f: no leftover backslash-escaped quotes in the sed program" 0
    else
        ok "$f: no leftover backslash-escaped quotes in the sed program" 1
    fi
done

echo
echo "== mask copies: form-independent redaction =="
for f in $SHELL_COPIES; do
    P="$WORK/prog.$$.$(basename "$f")"
    out=$(sed -E -f "$P" "$WORK/cases.txt" 2>/dev/null)
    leak=$(printf '%s\n' "$out" | grep -Eo "$RESIDUE_RE" | sort -u | tr '\n' ' ')
    [ -z "$leak" ] && ok "$(basename "$f"): 0 identifier residue across 7 shapes" 1 \
                   || ok "$(basename "$f"): identifier(s) survived: $leak" 0
    printf '%s\n' "$out" | grep -q 'serialVersionUID mismatch' \
        && ok "$(basename "$f"): negative control intact (serialVersionUID not over-masked)" 1 \
        || ok "$(basename "$f"): negative control was masked (over-redaction)" 0
    # The signal the diagnostics need must survive the redaction.
    printf '%s\n' "$out" | grep -q 'imei=' \
        && ok "$(basename "$f"): masked key still present (line is still diagnosable)" 1 \
        || ok "$(basename "$f"): masked line lost its key entirely" 0
done

echo
echo "== the JS copy must carry the same widened rules =="
grep -qF 'serialno|serial' module/webroot/js/logs.js \
    && ok "logs.js: serialno is in the key list" 1 \
    || ok "logs.js: serialno missing from the key list" 0
grep -qF '<redacted:len=' module/webroot/js/logs.js \
    && ok "logs.js: length-preserving redaction present" 1 \
    || ok "logs.js: length-preserving redaction missing" 0
# Positive check: the widened value class ("up to the next delimiter") must be
# there. (grep -F: the class contains regex metacharacters on purpose.)
grep -qF ';)\]}]+' module/webroot/js/logs.js \
    && ok "logs.js: widened value class present (r5)" 1 \
    || ok "logs.js: widened value class MISSING (r5 regression)" 0
# Negative check: the old alnum-only unquoted rule must be gone. The exact
# fragment is distinctive — the r5 comment mentions [A-Za-z0-9]{4,} but never
# with the '=(' that introduced the value.
if grep -qF '=([A-Za-z0-9]{4,})' module/webroot/js/logs.js; then
    ok "logs.js: old [A-Za-z0-9]{4,} unquoted rule is gone" 0
else
    ok "logs.js: old [A-Za-z0-9]{4,} unquoted rule is gone" 1
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
