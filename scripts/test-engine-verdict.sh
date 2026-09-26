#!/bin/sh
# test-engine-verdict.sh -- regression suite for module/engine-verdict.sh
#
# WHY. The verdict file ($TEE_DIR/.engine-verdict) is a *cached statement about
# a specific keybox*, and every reader (the WebUI probe, engine-check.sh, the
# scheduled fetch) must discard it the moment the keybox it describes is gone.
# The anchor decides that, and the anchor used to be the mtime alone -- which is
# the wrong anchor: several paths re-write keybox.xml with the SAME bytes
# (materialising a TrickyStore symlink at boot, restoring a pre-force backup,
# re-deploying an identical payload, an update install re-copying it). Those
# rewrites changed the mtime, so a perfectly valid verdict read as stale and the
# WebUI sat on "待引擎确认（keybox 刚变更）" forever (author's field report after
# a v3.2.3 -> v1.0.1 update). The contract this suite pins:
#
#   same bytes, new mtime  -> the verdict still applies (NOT stale)
#   different bytes        -> the verdict is stale, always
#   pre-2026-09-19 record  -> fall back to the mtime anchor
#
# The launcher.js probe duplicates the same rule in one long shell string (it
# cannot source this script). verify-artifact.sh asserts the two copies agree.
#
# Usage: sh scripts/test-engine-verdict.sh
# Exit : 0 all cases pass | 1 at least one case failed

set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
VERDICT="$HERE/module/engine-verdict.sh"
TMP=$(mktemp -d 2>/dev/null) || TMP="${TMPDIR:-/tmp}/engine-verdict.$$"
mkdir -p "$TMP" || exit 1
# Cleanup is an explicit call at the end, NOT a trap. An EXIT trap also fires in
# the subshells a capture creates, and on this host's bash shim that deadlocked
# the capture itself (the child had exited, the pipe never saw EOF) - the suite
# hung mid-case with every assertion green up to that point. A leftover mktemp
# directory on an early exit is the cheaper failure mode, and the recursive
# delete this would have used is exactly what host safe-delete hooks intercept
# (which is how a broken reset once looked "all green" here).
cleanup() {
    # Deliberately minimal. A multi-path delete goes through the host's
    # safe-delete wrapper, which blocks waiting for a confirmation it can never
    # get from a non-interactive suite - that hung this script after the last
    # assertion. A temp directory left behind costs nothing; a suite that never
    # prints its summary costs a lot.
    rm -f "$OUT" 2>/dev/null
    return 0
}

PASS=0
FAIL=0
OUT="$TMP/out"
# Each case gets its own TEE dir (no shared fixture to reset, no state leaking
# from a previous case - a stale .engine-verdict is precisely the failure this
# suite exists to catch).
_N=0
TEE=""; KB=""; ELOG=""; STATE=""
new_tee() {
    _N=$((_N + 1))
    TEE="$TMP/tee$_N"
    KB="$TEE/keybox.xml"
    ELOG="$TEE/log/teesim.log"
    STATE="$TEE/.engine-verdict"
    mkdir -p "$TEE/log" || exit 1
    # Synthetic keybox: engine-verdict.sh only hashes/stats it, it never parses
    # it (keybox-check.sh owns that job), so dummy bytes are honest here.
    printf '<AndroidAttestation>dummy-payload-A</AndroidAttestation>\n' > "$KB"
}

note() { printf '  %s\n' "$*"; }
bump_pass() { PASS=$((PASS + 1)); note "PASS $1"; }
bump_fail() {
    FAIL=$((FAIL + 1))
    note "FAIL $1"
    printf '%s\n' "--- child output ---"
    sed 's/^/         /' "$OUT" < /dev/null 2>/dev/null
    printf '%s\n' "--- verdict file ---"
    sed 's/^/         /' "$STATE" < /dev/null 2>/dev/null
}

# run <want-rc> [args...] -- runs the shipped script under a private TEE_DIR.
#
# The child's output is read straight from a file by the assertions below. It is
# never captured with $( ), because with a trap/subshell in play this host's bash
# shim deadlocked the capture (the child had exited, the pipe never saw EOF) and
# the suite hung mid-case with everything green up to that point. </dev/null
# keeps a reader-less child from blocking on inherited stdin.
run() {
    _want="$1"; shift
    : > "$OUT"
    # The timeout guard turns a hang into a visible rc=124 failure instead of a
    # suite that never finishes (a real risk for anything that shells out).
    if command -v timeout >/dev/null 2>&1; then
        AEGIS_TEE_DIR="$TEE" timeout 20 sh "$VERDICT" "$@" > "$OUT" 2>&1 < /dev/null
    else
        AEGIS_TEE_DIR="$TEE" sh "$VERDICT" "$@" > "$OUT" 2>&1 < /dev/null
    fi
    _rc=$?
    if [ "$_rc" -eq "$_want" ]; then
        bump_pass "$CASE (rc=$_rc)"
    else
        bump_fail "$CASE (want rc=$_want, got $_rc)"
    fi
}

# < /dev/null matters: sed with a missing file falls back to stdin and blocks
# forever inside a $( ) capture, which cost this suite one debugging round.
field() {
    [ -s "$STATE" ] || return 0
    sed -n "s/^$1=//p" "$STATE" < /dev/null 2>/dev/null
}
has_out() {
    if grep -q "$1" "$OUT" < /dev/null 2>/dev/null; then
        bump_pass "$CASE: $2"
    else
        bump_fail "$CASE: $2"
    fi
}
lacks_out() {
    if grep -q "$1" "$OUT" < /dev/null 2>/dev/null; then
        bump_fail "$CASE: $2"
    else
        bump_pass "$CASE: $2"
    fi
}

# ack <applied> <failed> -- replace the durable trace with one ack line
ack() {
    mkdir -p "$TEE/log"
    printf 'I TEESimulator: control: ack epoch=7 ok=true applied=%s failed=%s\n' "$1" "$2" > "$ELOG"
}

# reset_state -- fresh fixture for the next case (see new_tee)
reset_state() { new_tee; }

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

mtime_of() { stat -c %Y "$1" 2>/dev/null; }

# --- case 1: nothing recorded yet -> "unknown", and it must NOT claim staleness
CASE="no verdict recorded"
reset_state
run 2 show
has_out '^state=unknown' "reports state=unknown"

# --- case 2: a healthy engine -> ok, anchored on BOTH the content and the mtime
CASE="accepted keybox"
reset_state
ack 3 0
run 0 once
if [ "$(field state)" = "ok" ] && [ "$(field ack_applied)" = "3" ] && [ "$(field ack_failed)" = "0" ]; then
    bump_pass "$CASE: records state=ok with the ack counts"
else
    bump_fail "$CASE: records state=ok with the ack counts"
fi
if [ "$(field kbhash)" = "$(sha_of "$KB")" ] && [ -n "$(field kbhash)" ]; then
    bump_pass "$CASE: records the content anchor (kbhash)"
else
    bump_fail "$CASE: records the content anchor (kbhash)"
fi
if [ "$(field kbtm)" = "$(mtime_of "$KB")" ]; then
    bump_pass "$CASE: still records the legacy mtime anchor"
else
    bump_fail "$CASE: still records the legacy mtime anchor"
fi

# --- case 3: THE FIX. Same bytes, new mtime (symlink materialisation / backup
# restore / identical re-deploy) must NOT invalidate the verdict.
CASE="same bytes, rewritten file"
touch -t 200001010000 "$KB"
if [ "$(mtime_of "$KB")" != "$(field kbtm)" ]; then
    bump_pass "$CASE: fixture changed the mtime while keeping the bytes"
else
    bump_fail "$CASE: fixture changed the mtime while keeping the bytes"
fi
run 0 show
has_out '^state=ok' "the verdict still applies (this is the field bug)"
lacks_out '^state=stale' "not reported as stale"

# --- case 4: different bytes -> stale, unconditionally
CASE="changed keybox"
printf '<AndroidAttestation>dummy-payload-B</AndroidAttestation>\n' > "$KB"
run 2 show
has_out '^state=stale' "reports state=stale"

# --- case 5: re-taking the verdict clears it
CASE="re-taken verdict"
run 0 once
run 0 show
lacks_out '^state=stale' "stale cleared after a re-take"

# --- case 6: pre-2026-09-19 record (no kbhash) -> mtime fallback still works
CASE="legacy record, mtime matches"
reset_state
ack 2 0
printf 'state=ok\nreason=\nack_applied=2\nack_failed=0\nack=legacy\nkbtm=%s\nts=1\n' "$(mtime_of "$KB")" > "$STATE"
run 0 show
has_out '^state=ok' "accepted on the mtime anchor"
CASE="legacy record, mtime moved"
touch -t 200001010000 "$KB"
run 2 show
has_out '^state=stale' "stale on the mtime anchor"

# --- case 7: no ack in the trace -> "unknown", never a fabricated verdict
CASE="silent engine"
reset_state          # a case dir with no trace at all is the fixture here
run 2 once
if [ "$(field state)" = "unknown" ]; then
    bump_pass "$CASE: records state=unknown"
else
    bump_fail "$CASE: records state=unknown (got '$(field state)')"
fi

# --- case 8: applied=0 -> rejected, and the anchor is written for it too
CASE="refused keybox"
reset_state
printf 'I TEESimulator: teesim_km_init_ex: keybox chain is not Google-rooted\n' > "$ELOG"
ack 0 1
run 1 once
if [ "$(field state)" = "rejected" ]; then
    bump_pass "$CASE: records state=rejected"
else
    bump_fail "$CASE: records state=rejected (got '$(field state)')"
fi
run 1 show
has_out '^state=rejected' "show reports the refusal"

    # --- case 9: the admin-socket fallback (patch 0007; logcat-dead devices) ----
    # On a ROM with logging disabled the durable trace never fills, so `once` must
    # take the verdict from the daemon's in-memory push/ack state over the admin
    # socket. The socket helper is faked with a script printing canned /status
    # JSON; admin.sock only has to EXIST for the [ -e ] probe.
    mk_socket() {
        printf '#!/bin/sh\ncat <<'"'"'EJSON'"'"'\n%s\nEJSON\n' "$1" > "$TEE/teesim-uds"
        chmod 0755 "$TEE/teesim-uds"
        : > "$TEE/admin.sock"
        printf 'tok\n' > "$TEE/admin.token"
    }
    _ok_json='{"ok":true,"version":"","lib":{"hook":"keymint","api":36},"push":{"last":1760000000},"ack":{"last":1760000005,"applied":2,"failed":0}}'
    _rej_json='{"ok":true,"version":"","lib":{"hook":"keymint","api":36},"push":{"last":1760000000},"ack":{"last":1760000005,"applied":0,"failed":1}}'
    _old_json='{"ok":true,"version":"","lib":{"hook":"keymint","api":36},"push":{"last":1760000200},"ack":{"last":1760000005,"applied":2,"failed":0}}'

    CASE="socket fallback: accepted"
    reset_state
    mk_socket "$_ok_json"
    run 0 once
    if [ "$(field state)" = "ok" ] && [ "$(field ack_applied)" = "2" ]; then
        bump_pass "$CASE: records state=ok from the socket state"
    else
        bump_fail "$CASE: records state=ok from the socket state (got '$(field state)')"
    fi

    CASE="socket fallback: rejected"
    reset_state
    mk_socket "$_rej_json"
    run 1 once
    if [ "$(field state)" = "rejected" ]; then
        bump_pass "$CASE: records state=rejected from the socket state"
    else
        bump_fail "$CASE: records state=rejected from the socket state (got '$(field state)')"
    fi

    CASE="socket fallback: ack predates the last push"
    reset_state
    mk_socket "$_old_json"
    run 2 once
    if [ "$(field state)" = "unknown" ]; then
        bump_pass "$CASE: stays unknown when the ack predates the push (honest)"
    else
        bump_fail "$CASE: stays unknown when the ack predates the push (got '$(field state)')"
    fi

    cleanup
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
