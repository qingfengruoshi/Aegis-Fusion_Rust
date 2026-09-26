#!/system/bin/sh
# engine-verdict.sh — ask the ENGINE what it thinks of the deployed keybox, and
# record the answer in one place every other component reads.
#
# WHY THIS EXISTS. Two days were spent guessing at a keybox problem while the
# engine had already said, in one line, exactly what was wrong. The C++ side only
# manages "(bad keybox?)" (keymint_router.cpp:1190); the actual diagnosis is
# printed by the Rust TA's keybox parser, which logs its error verbatim:
#
#   E TEESimulator: teesim_km_init_ex: RSA: expected at least 2 certificates, found 1
#   E TEESimulator: teesim_km_init_ex: keybox parse: expected `>` not `<`
#   E TEESimulator: teesim_km_init_ex: EC: missing PrivateKey
#   E TEESimulator: teesim_km_init_ex: base64: Invalid symbol 45, offset 3
#   E TEESimulator: teesim_km_init_ex: keybox: no <Key algorithm="rsa"> or <Key algorithm="ecdsa">
#
# (rust/teesim-km/src/ffi.rs:172 logs every Ta::new_ex error with the
# Android-logger tag "TEESimulator", which is the tag LogTail captures into
# /data/adb/teesim/log/teesim.log — so the reason survives logcat rotation.)
#
# The ack is the other half. `applied` / `failed` count the profiles the
# interceptor actually put live; ok=true only means the message arrived:
#   I TEESimulator: control: ack epoch=... ok=true applied=0 failed=1   <- all dropped
#   I TEESimulator: control: ack epoch=... ok=true applied=1 failed=0   <- live
#
# Usage:
#   engine-verdict.sh once            evaluate the newest push/ack in the trace, record + print
#   engine-verdict.sh watch [secs] [byte-offset]   wait for the NEXT verdict (default 15s)
#   engine-verdict.sh show            print the recorded verdict (cheap; for the WebUI)
#   engine-verdict.sh reason          print only the engine's own words (empty if none)
#
# Exit: 0 = engine accepted (applied>0, failed=0)
#       1 = rejected (applied=0) or partial (applied>0 with failed>0)
#       2 = no verdict available (silent / wrong-keybox-in-flight / no trace)
#
# The recorded state lives in $TEE_DIR/.engine-verdict as `key=value` lines:
#   state=ok|rejected|partial|silent|unknown
#   reason=<the engine's own words>
#   ack_applied=N ack_failed=N ack=<the ack line>
#   kbtm=<keybox.xml mtime when this was recorded>   <- legacy anchor
#   kbhash=<sha256 of keybox.xml>                   <- staleness anchor
#   ts=<when we recorded it>
# A record whose anchor no longer matches the deployed keybox means the file
# changed since the verdict: the verdict is STALE and must not be displayed as
# the current state. kbhash is authoritative and kbtm is the fallback for
# records written before 2026-09-19 — see kb_hash() for why mtime alone was the
# wrong anchor.

TEE_DIR=${AEGIS_TEE_DIR:-/data/adb/teesim}
ELOG="$TEE_DIR/log/teesim.log"
KB="$TEE_DIR/keybox.xml"
STATE="$TEE_DIR/.engine-verdict"
WATCH_SECS=15

log_size() {
    s=$(wc -c < "$ELOG" 2>/dev/null)
    [ -n "$s" ] || s=0
    echo "$s"
}

# mask_ids — same rules as engine-check.sh (v3.2.3, audit N13): every tail of
# the durable engine log that reaches the terminal must be masked. The log can
# carry the upstream harvest line (plaintext IMEI/MEID/serial in pre-0006
# builds and pre-upgrade shards), and verdict output gets pasted into issues
# just like engine-check output does. Presence + length is all the diagnosis
# needs; this is the LAST known path around the H1 choke points.
# Kept byte-identical to engine-check.sh's copy, including the audit-r5
# widening (value class "up to the next delimiter", plus the `serialno` key) —
# scripts/test-mask-ids.sh asserts the four copies agree, so a fix applied to
# one of them cannot silently miss the other two.
mask_ids() {
    sed -E \
        -e "s/(secondImei|imei2|imei|meid|serialno|serial)='[^']*'/\1='<redacted>'/g" \
        -e "s/\"(secondImei|imei2|imei|meid|serialno|serial)\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"\1\":\"<redacted>\"/g" \
        -e "s/(secondImei|imei2|imei|meid|serialno|serial)[[:space:]]*=[[:space:]]*[^[:space:]'\",;)}]+/\1=<redacted>/g" \
        -e "s/(secondImei|imei2|imei|meid|serialno|serial)[[:space:]]+[^[:space:]'\",;)}]{4,}/\1 <redacted>/g"
}

kb_mtime() {
    m=$(stat -c %Y "$KB" 2>/dev/null)
    [ -n "$m" ] || m=0
    echo "$m"
}

# kb_hash — sha256 of the keybox CONTENT (empty when it cannot be computed).
#
# The staleness anchor used to be the mtime alone, and mtime is the wrong
# anchor: several paths re-write keybox.xml with the SAME bytes (materialising a
# TrickyStore symlink, restoring a pre-force backup, re-deploying an identical
# payload, an update install re-copying it). A verdict about those bytes is
# still correct, but the mtime no longer matched, so every reader called it
# stale. Field report (author, v3.2.3 -> v1.0.1 update): the WebUI sat on
# "待引擎确认（keybox 刚变更）" after a reboot and never converged, because
# nothing re-takes a verdict for a keybox that merely *looks* changed. The hash
# changes exactly when the engine would see different bytes, so it is the
# honest anchor; an empty hash (no sha256sum) falls back to kbtm in the reader.
kb_hash() {
    sha256sum "$KB" 2>/dev/null | cut -d' ' -f1
}

# socket_ack_state - the daemon's in-memory push/ack state over the admin socket
# (patch 0007 exposes it as /status fields). Prints
# "push=<epoch> ack=<epoch> applied=<n> failed=<n>" or nothing. The durable trace
# stays the primary source; this exists for devices where logcat is disabled and
# the LogTail mirror is structurally empty (field report 2026-09-20: durable file,
# in-memory ring and logcat ALL empty while the daemon ran and the interceptor was
# injected - every log-based signal died at once on that ROM).
socket_ack_state() {
    [ -x "$TEE_DIR/teesim-uds" ] || return 1
    [ -e "$TEE_DIR/admin.sock" ] || return 1
    [ -s "$TEE_DIR/admin.token" ] || return 1
    _out=$("$TEE_DIR/teesim-uds" "$TEE_DIR/admin.sock" GET /status "$(cat "$TEE_DIR/admin.token")" 2>/dev/null) || return 1
    _spe=$(printf '%s\n' "$_out" | grep -oE '"push":\{[^}]*\}' | grep -oE '"last":[0-9]+' | tail -1 | cut -d: -f2)
    _sae=$(printf '%s\n' "$_out" | grep -oE '"ack":\{[^}]*\}' | grep -oE '"last":[0-9]+' | tail -1 | cut -d: -f2)
    _sap=$(printf '%s\n' "$_out" | grep -oE '"ack":\{[^}]*\}' | grep -oE '"applied":-?[0-9]+' | tail -1 | cut -d: -f2)
    _sfl=$(printf '%s\n' "$_out" | grep -oE '"ack":\{[^}]*\}' | grep -oE '"failed":-?[0-9]+' | tail -1 | cut -d: -f2)
    [ -n "$_spe" ] && [ "$_spe" -gt 0 ] 2>/dev/null || return 1
    # One field per line - socket_verdict parses this format line by line.
    echo "push=$_spe"
    echo "ack=${_sae:-0}"
    echo "applied=${_sap:--1}"
    echo "failed=${_sfl:--1}"
}

# socket_verdict - derive a verdict from that state. Returns 0 and sets
# VERDICT_RC / ACK_APP / ACK_FLR / ACK_LINE when the daemon reports an ack for
# its CURRENT push; returns 1 when it does not (never pushed, or the last ack
# predates the last push). The keybox.xml content anchor does not apply here:
# this state describes the config the daemon is serving right now.
socket_verdict() {
    VERDICT_RC=""
    _s=$(socket_ack_state) || return 1
    _spe=$(printf '%s\n' "$_s" | sed -n 's/^push=//p')
    _sae=$(printf '%s\n' "$_s" | sed -n 's/^ack=//p')
    _sap=$(printf '%s\n' "$_s" | sed -n 's/^applied=//p')
    _sfl=$(printf '%s\n' "$_s" | sed -n 's/^failed=//p')
    [ -n "$_sae" ] && [ -n "$_spe" ] || return 1
    [ "$_sae" -ge "$_spe" ] 2>/dev/null || return 1
    ACK_LINE="socket: ack epoch=$_sae applied=$_sap failed=$_sfl"
    if [ "$_sap" -gt 0 ] 2>/dev/null; then
        VERDICT_RC=0; ACK_APP=$_sap; ACK_FLR=$_sfl; return 0
    fi
    if [ "$_sap" = 0 ]; then
        VERDICT_RC=1; ACK_APP=0; ACK_FLR=$_sfl; return 0
    fi
    return 1
}

# The engine's own words. This is THE answer to "why is this keybox bad?" —
# everything else in this repo is a restatement of it.
engine_reason() {
    r=$(grep -h "teesim_km_init_ex:" "$ELOG" 2>/dev/null | tail -1 | sed 's/.*teesim_km_init_ex: *//')
    if [ -z "$r" ]; then
        r=$(grep -h "Failed to resolve/push config" "$ELOG" 2>/dev/null | tail -1 | sed 's/.*TEESimulator: *//')
    fi
    if [ -z "$r" ]; then
        r=$(grep -h "No valid config to push" "$ELOG" 2>/dev/null | tail -1 | sed 's/.*TEESimulator: *//')
    fi
    printf '%s' "$r" | tr -d '\r\n' | cut -c1-220
}

# write_state <state> <applied> <failed> <ack-line>
# The reason is recorded ONLY for a refusal. engine_reason() reads the newest
# error in the whole trace, which may predate the current keybox — carrying it
# over to an "ok" verdict would show a stale complaint next to a healthy state.
write_state() {
    _s="$1"; _a="$2"; _f="$3"; _ack="$4"
    case "$_s" in
        rejected|partial) _r=$(engine_reason) ;;
        *) _r="" ;;
    esac
    {
        echo "state=$_s"
        echo "reason=$_r"
        echo "ack_applied=$_a"
        echo "ack_failed=$_f"
        echo "ack=$_ack"
        echo "kbtm=$(kb_mtime)"
        # Content anchor (2026-09-19). Omitted when sha256sum is unavailable, in
        # which case the reader falls back to kbtm.
        _h=$(kb_hash); [ -n "$_h" ] && echo "kbhash=$_h"
        echo "ts=$(date +%s)"
    } > "$STATE.tmp" 2>/dev/null && mv -f "$STATE.tmp" "$STATE" 2>/dev/null
    chmod 0644 "$STATE" 2>/dev/null
    return 0
}

latest_ack() {
    grep -h "control: ack" "$ELOG" 2>/dev/null | tail -1
}

# verdict_from <chunk> — parse the newest ack in a chunk of log and decide.
# Parsing the counts (not matching lines) is deliberate: a single line match
# reports "partial" as if it were "through".
verdict_from() {
    _chunk="$1"
    lastack=$(printf '%s\n' "$_chunk" | grep "control: ack" | tail -1)
    if [ -z "$lastack" ]; then
        # A staged/failed line can arrive before its ack; the ack is the summary.
        return 3
    fi
    app=$(printf '%s\n' "$lastack" | sed -n 's/.*applied=\([0-9]*\).*/\1/p')
    flr=$(printf '%s\n' "$lastack" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')
    [ -n "$app" ] || app=-1
    [ -n "$flr" ] || flr=-1
    ACK_LINE="$lastack"; ACK_APP="$app"; ACK_FLR="$flr"
    if [ "$app" -eq 0 ] 2>/dev/null; then
        return 1
    fi
    if [ "$app" -gt 0 ] 2>/dev/null && [ "$flr" -gt 0 ] 2>/dev/null; then
        return 1
    fi
    if [ "$app" -gt 0 ] 2>/dev/null; then
        return 0
    fi
    return 2
}

report() {
    case "$1" in
        0)
            echo "VERDICT: ACCEPTED — ack reports applied=$ACK_APP failed=$ACK_FLR: the engine is serving them."
            echo "         Give the client a moment, then re-run the integrity check; expect DEVICE/STRONG to change."
            return 0
            ;;
        1)
            if [ "$ACK_APP" = "0" ]; then
                echo "VERDICT: REJECTED — ack reports applied=0 failed=$ACK_FLR: no profile became live."
            else
                echo "VERDICT: PARTIAL — ack reports applied=$ACK_APP failed=$ACK_FLR."
                echo "         The rejected profiles are served by the real hardware HAL."
            fi
            _why=$(engine_reason)
            if [ -n "$_why" ]; then
                echo "         engine's own reason: $_why"
            else
                echo "         engine gave no parse error — check the ack and the daemon's push log."
            fi
            echo "         Every request falls through to the real HAL, so PI stays at BASIC."
            return 1
            ;;
        *)
            echo "VERDICT: SILENT — no ack in the trace for this keybox."
            echo "         Either the daemon is not running (probe: pidof teesim), the config"
            echo "         itself is invalid (ConfigStore rejects it before any push), or the"
            echo "         change has not been observed yet."
            return 2
            ;;
    esac
}

case "$1" in
    show)
        if [ -s "$STATE" ]; then
            rec=$(sed -n 's/^kbtm=//p' "$STATE" 2>/dev/null)
            rech=$(sed -n 's/^kbhash=//p' "$STATE" 2>/dev/null)
            st=$(sed -n 's/^state=//p' "$STATE" 2>/dev/null)
            # Content hash is authoritative when the record carries one; mtime is
            # only for records written before 2026-09-19 (see kb_hash).
            curh=$(kb_hash)
            stale=no
            if [ -n "$rech" ] && [ -n "$curh" ]; then
                [ "$curh" != "$rech" ] && stale=yes
            elif [ -n "$rec" ]; then
                [ "$(kb_mtime)" != "$rec" ] && stale=yes
            fi
            if [ "$stale" = yes ]; then
                echo "state=stale"
                echo "reason=keybox.xml changed since the last verdict; waiting for the engine"
                exit 2
            fi
            cat "$STATE"
            case "$st" in ok) exit 0 ;; rejected|partial) exit 1 ;; *) exit 2 ;; esac
        fi
        echo "state=unknown"
        echo "reason=no verdict recorded yet"
        exit 2
        ;;
    reason)
        engine_reason
        exit 0
        ;;
    once)
        verdict_from "$(cat "$ELOG" 2>/dev/null)"
        rc=$?
        if [ "$rc" = "3" ]; then
            # The trace holds no ack. On devices where logcat is disabled the
            # LogTail mirror is structurally empty (field report 2026-09-20), so
            # ask the daemon directly over the admin socket before giving up.
            if socket_verdict; then
                rc=$VERDICT_RC
            fi
        fi
        case "$rc" in
            3) write_state unknown "" "" "" ;;
            0) write_state ok "$ACK_APP" "$ACK_FLR" "$ACK_LINE" ;;
            1) write_state rejected "$ACK_APP" "$ACK_FLR" "$ACK_LINE" ;;
            *) write_state unknown "" "" "" ;;
        esac
        if [ "$rc" = "3" ]; then
            echo "VERDICT: NO-ACK — the durable trace holds no ack line."
            echo "         pushes=$(grep -c 'control: pushed config' "$ELOG" 2>/dev/null) — if"
            echo "         pushes>0 with no ack, the push never completed on the wire."
            exit 2
        fi
        report "$rc"
        exit "$rc"
        ;;
    watch)
        [ -n "$2" ] && case "$2" in *[!0-9]*) ;; *) WATCH_SECS="$2" ;; esac
        # v3.2.3 (audit N17): same numeric whitelist as $2. Callers pass pure
        # numbers ($(log_size)); a non-numeric value would only break test -lt
        # and arithmetic, but the check costs nothing and keeps the two
        # adjacent parameters consistent.
        from="$3"
        case "$from" in ''|*[!0-9]*) from="" ;; esac
        if [ -z "$from" ]; then from=$(log_size); fi
        i=0
        while [ "$i" -lt "$WATCH_SECS" ]; do
            now=$(log_size)
            if [ "$now" -lt "$from" ]; then
                chunk=$(cat "$ELOG" 2>/dev/null)          # rotated under us
            else
                chunk=$(tail -c "+$((from + 1))" "$ELOG" 2>/dev/null)
            fi
            case "$chunk" in
                *"control: ack"*|*"failed to build"*|*"cfg: staged profile"*)
                    echo "-- engine log since the deploy --"
                    printf '%s\n' "$chunk" | grep -E "pushed config|staged profile|failed to build|teesim_km_init_ex|control: ack|connection error" | tail -12
                    echo
                    verdict_from "$chunk"
                    rc=$?
                    if [ "$rc" = "3" ]; then
                        i=$((i + 1)); sleep 1; continue
                    fi
                    case "$rc" in
                        0) write_state ok "$ACK_APP" "$ACK_FLR" "$ACK_LINE" ;;
                        1) write_state rejected "$ACK_APP" "$ACK_FLR" "$ACK_LINE" ;;
                        *) write_state unknown "" "" "" ;;
                    esac
                    report "$rc"
                    exit "$rc"
                    ;;
            esac
            i=$((i + 1))
            sleep 1
        done
        # Logcat-dead devices (see `once`): the log never fills, so give the admin
        # socket one chance before declaring silence.
        if socket_verdict; then
            case "$VERDICT_RC" in
                0) write_state ok "$ACK_APP" "$ACK_FLR" "$ACK_LINE" ;;
                1) write_state rejected "$ACK_APP" "$ACK_FLR" "$ACK_LINE" ;;
            esac
            report "$VERDICT_RC"
            exit "$VERDICT_RC"
        fi
        write_state silent "" "" ""
        echo "VERDICT: SILENT — nothing in ${WATCH_SECS}s. Recent lines:"
        # v3.2.3 (audit N13): the tail is masked like every other engine-log
        # excerpt that reaches a terminal (H1 choke-point policy; see the
        # engine-check.sh header for the threat model).
        tail -c 2000 "$ELOG" 2>/dev/null | mask_ids | tail -8
        exit 2
        ;;
    socket-live)
        # For scripts (keybox-fetch's engine_verifiable): exit 0 when the daemon
        # reports an ack for its current push, without consulting any log file.
        if socket_verdict; then
            echo "state=$VERDICT_RC ack=$ACK_LINE"
            exit 0
        fi
        echo "state=none"
        exit 2
        ;;
    ""|-h|--help)
        echo "engine-verdict.sh — the engine's own answer about the deployed keybox"
        echo
        echo "  engine-verdict.sh once                 judge the newest push/ack now, record it"
        echo "  engine-verdict.sh watch [secs] [from]   wait for the next verdict (default 15s)"
        echo "  engine-verdict.sh show                 print the recorded verdict"
        echo "  engine-verdict.sh reason               print only the engine's own words"
        echo "  engine-verdict.sh socket-live           0 when the admin socket reports an ack"
        echo
        echo "  exit 0 = accepted · 1 = rejected/partial · 2 = no verdict"
        exit 0
        ;;
esac
echo "unknown mode: $1 (try --help)" >&2
exit 2
