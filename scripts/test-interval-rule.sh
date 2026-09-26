#!/bin/sh
# test-interval-rule.sh -- the refresh interval has ONE meaning everywhere
#
# The interval lives in /data/adb/teesim/keybox-refresh. It is DESCRIBED in
# three places (the installer summary, the WebUI dashboard, the diagnostics
# export) and EXECUTED in one (service.sh's hourly loop). The author's rule:
# no two of them may ever disagree -- a display that says 24h while the engine
# runs 6, or an installer that claims 12h over a loop running 24, makes every
# display worthless. test-webui.js and test-logs.js pin the display sites;
# THIS suite pins the two shell parsers by extracting the very lines that
# ship (never copies of them) and running them against fixtures:
#
#   installer (customize.sh): absent -> 24, "12" -> 12, junk -> 24, " 48 " -> 48
#   executor  (service.sh):   same parse, then honoured: 0 never runs,
#                             otherwise run once tick >= interval
#
# Plus the structural invariants that make divergence impossible:
#   - exactly ONE writer (the WebUI's interval pill); no shell script writes it
#   - the executor's decision line is the expected idiom (tick >= interval, 0 off)
#   - the installer's "existing installation detected" line quotes $_kbiv, so the
#     number it prints cannot be a constant that drifts from the summary
#
# Usage: sh scripts/test-interval-rule.sh
# Exit : 0 all cases pass | 1 at least one case failed

set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
CUSTOM="$HERE/module/customize.sh"
SERVICE="$HERE/module/service.sh"
LAUNCHER="$HERE/module/webroot/js/launcher.js"
TMP=$(mktemp -d 2>/dev/null) || TMP="${TMPDIR:-/tmp}/interval-rule.$$"
mkdir -p "$TMP" || exit 1
# The extracted shell lines embed the data-dir path, so the fixture path that is
# substituted into them must be backslash-free: inside the harness's unquoted
# $(cat ...) a Windows backslash path is eaten as escape characters and the read
# silently fails (which looks exactly like "the parse returned the default" -
# the false failure that cost one debugging round on this host).
TMP_FWD=$(printf '%s' "$TMP" | tr '\\' '/')

PASS=0
FAIL=0

note() { printf '  %s\n' "$*"; }
bump_pass() { PASS=$((PASS + 1)); note "PASS $1"; }
bump_fail() { FAIL=$((FAIL + 1)); note "FAIL $1"; }

cleanup() {
    # Minimal on purpose: multi-path deletes go through host safe-delete
    # wrappers that can block a non-interactive suite (see test-engine-verdict.sh).
    rm -f "$TMP"/h*.sh "$TMP"/keybox-refresh "$TMP"/out 2>/dev/null
    rmdir "$TMP" 2>/dev/null
    return 0
}

D="$TMP_FWD/data"   # stands in for /data/adb/teesim in the extracted lines

# --- fixture: the two REAL installer parser lines, path substituted ----------
P1=$(grep -n '^_kbiv=' "$CUSTOM" | cut -d: -f1 | head -1)
P2=$(grep -n '^case "\$_kbiv"' "$CUSTOM" | cut -d: -f1 | head -1)
if [ -n "$P1" ] && [ -n "$P2" ] && [ "$P2" -gt "$P1" ]; then
    bump_pass "installer: found the shipped parser lines"
else
    bump_fail "installer: could not locate the shipped parser lines"
fi
{
    printf 'msg(){ :; }\n'
    sed "s|/data/adb/teesim|$D|g" "$CUSTOM" | sed -n "${P1},${P2}p"
    printf 'printf "%%s" "$_kbiv"\n'
} > "$TMP/h1.sh"

parse_installer() {   # $1 = file content ("ABSENT" for no file)
    if [ "$1" = "ABSENT" ]; then rm -f "$D/keybox-refresh" 2>/dev/null
    else printf '%s' "$1" > "$D/keybox-refresh"; fi
    sh "$TMP/h1.sh" < /dev/null 2>/dev/null
}

# --- fixture: the REAL executor lines (parse + the inheritance decision) -----
S1=$(grep -n 'iv=$(cat /data/adb/teesim/keybox-refresh' "$SERVICE" | cut -d: -f1 | head -1)
S2=$((S1 + 1))
L1=$(grep -n 'now=$(date +%s)' "$SERVICE" | cut -d: -f1 | head -1)
L3=$((L1 + 2))
D1=$(grep -n 'ge "$((iv \* 3600))"' "$SERVICE" | cut -d: -f1 | head -1)
if [ -n "$S1" ] && [ -n "$L1" ] && [ -n "$D1" ]; then
    bump_pass "executor: found the shipped parser + inheritance-decision lines"
else
    bump_fail "executor: could not locate the shipped lines"
fi
SVCSUB="$TMP/svc-sub.sh"
sed "s|/data/adb/teesim|$D|g" "$SERVICE" > "$SVCSUB"
{
    # FAKE_NOW pins "now"; a date() function shadows the external date binary.
    printf 'FAKE_NOW=1760000000\n'
    printf 'date(){ printf "%%s" "$FAKE_NOW"; }\n'
    sed -n "${S1},${S2}p" "$SVCSUB"
    sed -n "${L1},${L3}p" "$SVCSUB"
    sed -n "${D1}p" "$SVCSUB"
    printf '    echo RUN\nelse\n    echo SKIP\nfi\n'
} > "$TMP/h2.sh"

run_executor() {      # $1 = keybox-refresh content, $2 = stamp age seconds (ABSENT = no file)
    if [ "$1" = "ABSENT" ]; then rm -f "$D/keybox-refresh" 2>/dev/null
    else printf '%s' "$1" > "$D/keybox-refresh"; fi
    if [ "$2" = "ABSENT" ]; then rm -f "$D/.kb-last-fetch" 2>/dev/null
    else touch -d "@$((1760000000 + $2))" "$D/.kb-last-fetch" 2>/dev/null; fi
    sh "$TMP/h2.sh" < /dev/null 2>/dev/null
}

check() {             # check <want> <got> <name>
    if [ "$2" = "$1" ]; then bump_pass "$3"
    else bump_fail "$3 (want [$1], got [$2])"; fi
}

mkdir -p "$D"

# --- installer parser: the summary's number comes from the file -------------
check 24  "$(parse_installer ABSENT)" "installer: no file -> default 24"
check 12  "$(parse_installer 12)"     "installer: 12 -> 12 (the field report)"
check 6   "$(parse_installer 6)"      "installer: an off-pill value shows as itself"
check 48  "$(parse_installer ' 48 ')" "installer: surrounding whitespace stripped"
check 24  "$(parse_installer abc)"    "installer: junk -> default 24"

# --- executor parser: identical parse, then honoured (RUN/SKIP carries the
# --- parsed interval, so both halves of "display == behaviour" are pinned) ---
# --- executor: parse + the inherited schedule (RUN/SKIP vs the set interval) ---
check "RUN"  "$(run_executor ABSENT ABSENT)"  "executor: fresh install (no stamp) -> due at boot"
check "SKIP" "$(run_executor 12 -39600)"      "executor: 12h set, last success 11h ago -> waits"
check "RUN"  "$(run_executor 12 -46800)"      "executor: 12h set, last success 13h ago -> due"
check "SKIP" "$(run_executor 0 ABSENT)"       "executor: 0 (off) NEVER fetches"
check "RUN"  "$(run_executor junk -90000)"    "executor: junk interval -> default 24h, 25h old -> due"
check "SKIP" "$(run_executor 12 0)"           "executor: a just-now manual refresh re-arms the schedule"

# --- structural invariants --------------------------------------------------
if [ "$(grep -c '\$((now - lfts))" -ge "\$((iv \* 3600))' "$SERVICE")" = 1 ]; then
    bump_pass "executor: decision is the inheritance idiom (now - last >= interval)"
else
    bump_fail "executor: decision idiom changed or duplicated"
fi
_w=$(grep -c "exec('echo ' + v + ' > ' + TEE_DIR + '/keybox-refresh')" "$LAUNCHER")
if [ "$_w" = 1 ] && ! grep -qE '> */data/adb/teesim/keybox-refresh' "$CUSTOM" "$SERVICE"; then
    bump_pass "single writer: only the WebUI pill writes keybox-refresh"
else
    bump_fail "single writer: unexpected writer found ($_w)"
fi
if grep -q '自动获取每 \${_kbiv} 小时' "$CUSTOM" && grep -q 'auto-fetch every \${_kbiv}h' "$CUSTOM"; then
    bump_pass "installer: the kept-settings line quotes \$_kbiv, not a constant"
else
    bump_fail "installer: the kept-settings line does not quote \$_kbiv"
fi
_kbpre_set=$(grep -n '^_kbpre=no' "$CUSTOM" | cut -d: -f1 | head -1)
_kbpre_use=$(grep -n 'if \[ "\$_kbpre" = yes \]; then' "$CUSTOM" | cut -d: -f1 | head -1)
if [ -n "$_kbpre_set" ] && [ -n "$_kbpre_use" ] && [ "$_kbpre_set" -lt "$_kbpre_use" ]; then
    bump_pass "installer: the kept-settings line is guarded by _kbpre (set before use)"
else
    bump_fail "installer: _kbpre guard missing or out of order"
fi

# --- summary wording: the OFF branch must not fabricate a cadence -----------
A=$(grep -n '^if \[ "\$_kbiv" = "0" \]; then' "$CUSTOM" | cut -d: -f1 | head -1)
B=$(awk -v s="$A" 'NR >= s && /^fi$/ { print NR; exit }' "$CUSTOM")
if [ -n "$A" ] && [ -n "$B" ]; then
    {
        printf 'msg(){ printf "%%s\\n" "$2"; }\n'
        sed -n "${A},${B}p" "$CUSTOM"
    } > "$TMP/h3.sh"
    printf '_kbiv=12\n' > "$TMP/h3b.sh"; cat "$TMP/h3.sh" >> "$TMP/h3b.sh"
    printf '_kbiv=0\n'  > "$TMP/h3c.sh"; cat "$TMP/h3.sh" >> "$TMP/h3c.sh"
    _w12=$(sh "$TMP/h3b.sh" < /dev/null 2>/dev/null | tr '\n' ' ')
    _w0=$(sh "$TMP/h3c.sh" < /dev/null 2>/dev/null | tr '\n' ' ')
    case "$_w12" in *每\ 12\ 小时*) bump_pass "summary: 12 renders as 每 12 小时";; *) bump_fail "summary: 12 rendered as [$_w12]";; esac
    case "$_w0" in *已关闭*) bump_pass "summary: 0 renders as 已关闭, never a cadence";; *) bump_fail "summary: 0 rendered as [$_w0]";; esac
else
    bump_fail "summary: could not locate the OFF/else block"
fi

cleanup
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
