#!/system/bin/sh
# keybox-swap.sh — deploy a keybox and read the engine's verdict about it, live.
#
# WHY THIS EXISTS. Whether a keybox works is not a property anyone can judge by
# reading it: the only authority is the TA inside keystore2, and it tells you in
# exactly three log lines — an ack with counts, and (when it refuses) its own
# reason. So the way to settle it is to hand the engine a candidate and read what
# it says: a round trip that takes about a second, with no reboot, no reflash and
# no reinstall. This script does the handoff and waits for the answer.
#
# HOW THE HANDOFF WORKS (why no reboot is needed). The daemon registers a
# directory-level FileObserver on /data/adb/teesim for CLOSE_WRITE|MOVED_TO|
# DELETE (upstream: ConfigStore.watch), and on any event whose path is
# "config.json" or ends in ".xml" it calls resolveAndPush() — as does
# KeyAdmin.onRescan and the first boot push. Replacing keybox.xml is therefore
# itself the trigger. Note the rename: we cp into the SAME directory and mv over
# the target, so the replace is an atomic rename (MOVED_TO) rather than a
# write-through — cp onto a symlinked keybox.xml would silently rewrite whatever
# the link points at (e.g. TrickyStore's own copy) instead of replacing the link.
#
# After the ack the DAEMON re-attests the target apps' pre-existing keys by
# itself (Control.kt: onCommitted -> ReAttest.run), restarting keystore2 only if
# its database fallback is needed. Nothing here has to kill anything.
#
# THE ANSWERS (engine-verdict.sh owns the parsing; this script just calls it):
#   ACCEPTED  I cfg: staged profile 'default' (...)  ·  ack applied=1 failed=0
#   REJECTED  E keymint: profile default failed to build (bad keybox?)
#             ack applied=0 failed=1  ·  plus the engine's own words, e.g.
#             E teesim_km_init_ex: RSA: expected at least 2 certificates, found 1
#
# Usage:
#   keybox-swap.sh <candidate.xml>       validate, back up, deploy, print the verdict
#   keybox-swap.sh <candidate.xml> -f    deploy even if validation fails (read the engine's own answer)
#   keybox-swap.sh --auto <c1.xml> [...] try each candidate until the ENGINE accepts one
#   keybox-swap.sh --watch [secs]        change nothing; just watch the next push+ack
#   keybox-swap.sh --restore             put the newest backup back
#   keybox-swap.sh --list                list backups

TEE_DIR=${AEGIS_TEE_DIR:-/data/adb/teesim}
MODDIR=${AEGIS_MODDIR:-/data/adb/modules/aegisfusion_rs}
CFG="$TEE_DIR/config.json"
KB="$TEE_DIR/keybox.xml"
ELOG="$TEE_DIR/log/teesim.log"
BKDIR="$TEE_DIR/keybox-backups"
CHECK="$MODDIR/keybox-check.sh"
VERDICT="$MODDIR/engine-verdict.sh"
WATCH_SECS=15

log_size() {
    s=$(wc -c < "$ELOG" 2>/dev/null)
    [ -n "$s" ] || s=0
    echo "$s"
}

# watch_verdict <byte-offset> <seconds> — delegate to engine-verdict.sh, which
# owns the single reading of the trace: it parses the ack COUNTS (a single-line
# match reports "partial" as if it were "through") and pulls the engine's own
# reason out of teesim_km_init_ex. It also records the result in
# $TEE_DIR/.engine-verdict, which is what the WebUI displays.
watch_verdict() {
    from="$1"; secs="$2"
    if [ ! -f "$VERDICT" ]; then
        echo "VERDICT: SILENT — $VERDICT is missing, so the trace cannot be read."
        echo "         (reinstall/upgrade the module: engine-verdict.sh ships with it)"
        return 2
    fi
    sh "$VERDICT" watch "$secs" "$from"
    return $?
}

# deploy <candidate> — atomic replace, backing up the current bytes first.
# cp into the SAME directory + rename: an atomic MOVED_TO for the daemon's
# watcher, and it replaces a symlink instead of writing through it.
deploy() {
    _c="$1"
    mkdir -p "$BKDIR" 2>/dev/null
    if [ -s "$KB" ]; then
        _ts=$(date +%Y%m%d-%H%M%S)
        if cp -fL "$KB" "$BKDIR/keybox.$_ts.xml" 2>/dev/null; then   # -L: follow a symlink, keep the bytes
            echo "backed up current keybox -> $BKDIR/keybox.$_ts.xml"
            ls -1t "$BKDIR"/*.xml 2>/dev/null | tail -n +11 | while read -r old; do
                echo "pruning old backup: $(basename "$old")"
                rm -f "$old"
            done
        else
            # v3.2.3 (audit N15): fail-closed, aligned with keybox-fetch.sh's
            # --force backup (audit M11). The old behaviour only warned and
            # then replaced the keybox anyway — an unwritable backup dir or a
            # full disk silently destroyed the user's (possibly imported,
            # irreplaceable) keybox. Nothing gets replaced we cannot restore.
            echo "abort: could not back up the current keybox — nothing was replaced"
            echo "       (check that $BKDIR is writable and the disk has space), then retry"
            return 2
        fi
        [ -L "$KB" ] && echo "note: current keybox.xml is a symlink -> $(readlink "$KB") (its bytes, not the link, are what was backed up)"
    fi
    MARK=$(log_size)
    cp -f "$_c" "$KB.new" 2>/dev/null || { echo "deploy failed: cannot write $KB.new"; return 2; }
    mv -f "$KB.new" "$KB" 2>/dev/null || { echo "deploy failed: cannot replace $KB"; return 2; }
    chmod 0600 "$KB" 2>/dev/null
    chown 0:0 "$KB" 2>/dev/null
    echo "deployed $_c -> $KB ($(wc -c < "$KB" 2>/dev/null) bytes)"
    [ -f "$TEE_DIR/.auto-keybox" ] && rm -f "$TEE_DIR/.auto-keybox"
    return 0
}

# validate <candidate> <force> — the same structural pre-check the installer and
# the fetcher use. It cannot prove usability (only the engine can), but it stops
# the obvious wastes of a round trip.
validate() {
    _c="$1"; _force="$2"
    [ -f "$CHECK" ] || { echo "warn: $CHECK not found; deploying unvalidated"; return 0; }
    if sh "$CHECK" "$_c"; then
        return 0
    fi
    echo
    if [ -n "$_force" ]; then
        echo "(--force) deploying anyway so the engine can be heard from directly."
        return 0
    fi
    echo "REFUSING to deploy: the validator says the engine cannot use this keybox."
    echo "Re-run with -f to deploy it anyway and read the engine's own verdict."
    return 1
}

case "$1" in
    --list)
        ls -la "$BKDIR" 2>/dev/null || echo "no backups yet ($BKDIR)"
        exit 0
        ;;
    --restore)
        newest=$(ls -1t "$BKDIR"/*.xml 2>/dev/null | head -1)
        [ -n "$newest" ] || { echo "no backup to restore in $BKDIR"; exit 2; }
        echo "restoring $newest"
        cp -f "$newest" "$KB.new" && mv -f "$KB.new" "$KB" && chmod 0600 "$KB"
        MARK=$(log_size); sleep 1
        watch_verdict "$MARK" "$WATCH_SECS"
        exit $?
        ;;
    --watch)
        [ -n "$2" ] && case "$2" in *[!0-9]*) ;; *) WATCH_SECS="$2" ;; esac
        echo "watching $ELOG for the next push/ack (up to ${WATCH_SECS}s, nothing changed)…"
        echo "hint: touch a keybox or edit config.json from another shell to force a re-push"
        watch_verdict "$(log_size)" "$WATCH_SECS"
        exit $?
        ;;
    --auto)
        shift
        [ -n "$1" ] || { echo "usage: keybox-swap.sh --auto <c1.xml> [c2.xml ...]"; exit 2; }
        # Snapshot the pre-run state explicitly. "the newest backup" would be WRONG
        # here: deploy() backs up before EVERY candidate, so the newest backup is
        # the previous candidate, not what was deployed when this run started.
        PRE="$TEE_DIR/.keybox.prerun.xml"
        rm -f "$PRE"
        [ -s "$KB" ] && cp -fL "$KB" "$PRE" 2>/dev/null
        n=0
        tried=0
        for c in "$@"; do
            n=$((n + 1))
            echo
            echo "=== candidate $n: $c ==="
            [ -f "$c" ] || { echo "not a file: $c (skipped)"; continue; }
            if ! validate "$c" ""; then
                echo "skipped: failed the structural pre-check (use -f on a single candidate to override)"
                continue
            fi
            tried=$((tried + 1))
            deploy "$c" || continue
            echo "waiting for the engine to re-push (the watch triggers on this rename)…"
            watch_verdict "$MARK" "$WATCH_SECS"
            rc=$?
            if [ "$rc" = 0 ]; then
                echo
                echo "ACCEPTED: $c is now the deployed keybox and the engine is serving it."
                rm -f "$PRE"
                exit 0
            fi
            echo "not usable — trying the next candidate (current file kept in $BKDIR)"
        done
        echo
        echo "FAILED: none of the $n candidate(s) was accepted by the engine ($tried reached the engine)."
        if [ -s "$PRE" ]; then
            echo "restoring the keybox that was deployed before this run"
            cp -f "$PRE" "$BKDIR/keybox.prerun.$(date +%Y%m%d-%H%M%S).xml" 2>/dev/null
            cp -f "$PRE" "$KB.new" && mv -f "$KB.new" "$KB" && chmod 0600 "$KB"
            rm -f "$PRE"
            MARK=$(log_size); sleep 1
            watch_verdict "$MARK" "$WATCH_SECS"
        else
            echo "(nothing to restore: no keybox was deployed before this run)"
        fi
        exit 1
        ;;
    ""|-h|--help)
        echo "keybox-swap.sh — deploy a keybox and read the engine's verdict, live"
        echo
        echo "  keybox-swap.sh <candidate.xml>      validate, back up, deploy, print the verdict"
        echo "  keybox-swap.sh <candidate.xml> -f   deploy even if validation fails (read the engine's own answer)"
        echo "  keybox-swap.sh --auto <c1> [c2...]  try each candidate until the engine accepts one"
        echo "  keybox-swap.sh --watch [secs]       change nothing; just watch the next push+ack (default 15s)"
        echo "  keybox-swap.sh --restore            put the newest backup back"
        echo "  keybox-swap.sh --list               list backups"
        echo
        echo "  exit 0 = engine accepted the keybox · 1 = rejected · 2 = silent (no push/ack seen)"
        echo "  a rejection prints the ENGINE'S OWN REASON (from teesim_km_init_ex)."
        echo "  backups live in $BKDIR (newest 10 kept)"
        exit 0
        ;;
esac

CAND="$1"
FORCE=""
if [ "$2" = "-f" ] || [ "$2" = "--force" ]; then FORCE=1; fi

[ -f "$CAND" ] || { echo "not a file: $CAND"; exit 2; }

validate "$CAND" "$FORCE" || exit 1
deploy "$CAND" || exit 2

echo "waiting for the engine to re-push (the watch triggers on this rename)…"
watch_verdict "$MARK" "$WATCH_SECS"
RC=$?
[ "$RC" -eq 0 ] && echo && echo "note: the committed push also re-attests the target apps' existing"
[ "$RC" -eq 0 ] && echo "      attest keys (the daemon does it on the ack), so their next request"
[ "$RC" -eq 0 ] && echo "      is served from this keybox."
exit "$RC"
