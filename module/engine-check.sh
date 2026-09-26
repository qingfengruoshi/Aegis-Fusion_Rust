#!/system/bin/sh
# engine-check.sh — one-shot health report for the TEE half.
#
# Answers the question that used to take a dozen round trips: IS THE ENGINE
# ACTUALLY SERVING REQUESTS? A daemon that runs but never pushes a config looks
# perfectly healthy from the outside (process alive, lib injected, keybox
# deployed) while every app still gets the real hardware attestation.
#
# Run from a root shell:  sh /data/adb/modules/aegisfusion_rs/engine-check.sh
# Output is plain text (safe to paste): no keybox contents are printed, and
# device identifiers (IMEI/IMEI2/MEID/serial) are masked in every log tail
# (v3.2.3, audit H1) — the harvest line reads "imei='<redacted>'" here. The
# /status JSON is never printed raw either: it embeds the full harvest record,
# so section 6 only prints the version/hook fields (v3.2.3, audit N1).
#
# v3.1.2 revisions — both were wrong-signal bugs, not cosmetics:
#   1. The daemon was probed with `pgrep -f org.matrix.teesim`, which NEVER
#      matches: app_process rewrites argv[0], so /proc/<pid>/cmdline reads
#      "teesim". Every report up to v3.1.2 said the daemon was down while it was
#      running fine. `pidof teesim` is the only correct probe.
#   2. The verdict was read from logcat, which rotates the boot-time decision
#      trail away within minutes — exactly the window in which "did the config
#      ever reach the interceptor?" is answerable. The engine already keeps a
#      DURABLE trace (LogTail -> /data/adb/teesim/log/teesim.log); we read that
#      first and only fall back to logcat.

MODDIR=${AEGIS_MODDIR:-/data/adb/modules/aegisfusion_rs}
TEE_DIR=${AEGIS_TEE_DIR:-/data/adb/teesim}
ELOG="$TEE_DIR/log/teesim.log"          # durable LogTail ring (teesim.log + parts)
SOCK_CTL=/data/misc/keystore/.teesim-ctl
SOCK_ADMIN="$TEE_DIR/admin.sock"
TOKEN="$TEE_DIR/admin.token"
UDS="$TEE_DIR/teesim-uds"

say() { echo "$*"; }
head_() { echo; echo "== $* =="; }
have() { command -v "$1" >/dev/null 2>&1; }

# mask_ids — strip device identifiers from log tails before they reach the
# terminal/paste buffer (v3.2.3, audit H1): the upstream harvest line prints
# plaintext imei/secondImei/meid/serial, and this script's output is pasted
# into bug reports. Presence + length is what diagnosis needs, not the value.
# v3.2.3 (audit N1): a third rule covers the JSON form `"key":"value"` — the
# /status response embeds harvest data as JSON, which the original two rules
# (key='v', key=v) let through verbatim. /status is field-filtered as well,
# so this is belt and braces, not the only line of defence.
# v3.2.3 (audit r5): the unquoted rule is no longer coupled to ONE upstream
# spelling. [A-Za-z0-9]{4,} right after '=' let a hyphenated value, a value
# whose first alphanumeric run was shorter than four, and a space-separated
# value through; the value class is now "anything up to the next delimiter",
# and `serialno` is masked too (that is the property the engine reads, so
# "ro.serialno=…" must not survive either). A value wrapped onto the NEXT line
# needs no rule here: every line of the durable log is one complete record, so
# a bare "imei=" at end-of-line cannot occur (the JS export masks the joined
# text, where it *could*; see maskDeviceIds in webroot/js/logs.js).
mask_ids() {
    sed -E \
        -e "s/(secondImei|imei2|imei|meid|serialno|serial)='[^']*'/\1='<redacted>'/g" \
        -e "s/\"(secondImei|imei2|imei|meid|serialno|serial)\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"\1\":\"<redacted>\"/g" \
        -e "s/(secondImei|imei2|imei|meid|serialno|serial)[[:space:]]*=[[:space:]]*[^[:space:]'\",;)}]+/\1=<redacted>/g" \
        -e "s/(secondImei|imei2|imei|meid|serialno|serial)[[:space:]]+[^[:space:]'\",;)}]{4,}/\1 <redacted>/g"
}

# count_pat <file> <pattern> — a grep -c that is safe on a missing file and never
# emits two lines (grep -c prints 0 AND exits 1, so `|| echo 0` would double it).
count_pat() {
    c=$(grep -c "$2" "$1" 2>/dev/null)
    [ -n "$c" ] || c=0
    echo "$c"
}

head_ "1. module / daemon process"
echo "module dir : $MODDIR"
[ -f "$MODDIR/module.prop" ] && grep -E '^(version|versionCode)=' "$MODDIR/module.prop"
# pidof, NOT pgrep -f: app_process rewrites the process name to "teesim", so the
# java class name never appears in cmdline and pgrep -f finds nothing.
DPID=$(pidof teesim 2>/dev/null)
if [ -n "$DPID" ]; then
    echo "daemon pid : $DPID (alive)"
    echo "daemon cmd : $(tr '\0' ' ' < /proc/$DPID/cmdline 2>/dev/null)"
    echo "daemon up  : $(ps -o etime= -p "$DPID" 2>/dev/null | tr -d ' ')"
else
    echo "daemon pid : NONE — the control daemon is NOT running"
    echo "  -> the respawn loop in service.sh restarts it within ~2s; if it keeps"
    echo "     dying, section 7 (daemon.log) holds the stack trace."
fi
echo "daemon.log : $([ -f "$TEE_DIR/daemon.log" ] && echo "$(wc -c < "$TEE_DIR/daemon.log") bytes" || echo MISSING)"

head_ "2. interceptor injection into keystore2"
KPID=$(pidof keystore2 2>/dev/null | head -1)
if [ -n "$KPID" ]; then
    echo "keystore2 pid : $KPID"
    echo "libteesim maps: $(grep -c libteesim /proc/$KPID/maps 2>/dev/null)"
else
    echo "keystore2 pid : NOT RUNNING"
fi

head_ "3. control socket (daemon <-> interceptor)"
if [ -S "$SOCK_CTL" ]; then
    ls -la "$SOCK_CTL"
    echo "socket: present"
else
    echo "socket: MISSING ($SOCK_CTL)"
    echo "  -> the interceptor never came up far enough to listen: keystore2 may"
    echo "     have started before the lib was injected, or the bind failed."
fi

head_ "4. config the daemon would push"
if [ -f "$TEE_DIR/config.json" ]; then
    echo "config.json : $(wc -c < "$TEE_DIR/config.json") bytes"
    grep -o '"mode"[^,]*' "$TEE_DIR/config.json" | head -1
    grep -o '"keybox"[^,]*' "$TEE_DIR/config.json" | head -1
    echo "profiles    : $(grep -c '"mode"' "$TEE_DIR/config.json")"
    echo "apps entries: $(grep -o '"apps"' "$TEE_DIR/config.json" | wc -l) apps[] array(s)"
else
    echo "config.json : MISSING — the daemon pushes nothing without it"
fi
# Every keybox the config actually names, so a mismatch between the config's
# "keybox" field and the file on disk is visible instead of implied. Each one is
# run through the SAME structural validator the installer and the fetch deploy
# path use — a keybox the engine cannot build a TA from produces exactly one
# line of output ("failed to build (bad keybox?)") and then silently costs every
# profile, which is indistinguishable from "nothing is configured" downstream.
KBC="$MODDIR/keybox-check.sh"
for kb in $(grep -o '"keybox"[[:space:]]*:[[:space:]]*"[^"]*"' "$TEE_DIR/config.json" 2>/dev/null \
            | sed 's/.*:[[:space:]]*"//;s/"$//' | sort -u); do
    f="$TEE_DIR/$kb"
    if [ -s "$f" ]; then
        echo "keybox      : $kb ($(wc -c < "$f") bytes)"
        [ -L "$f" ] && echo "  note: symlink -> $(readlink "$f" 2>/dev/null) (a link can be re-pointed under the engine)"
        if [ -f "$KBC" ]; then
            sh "$KBC" "$f" 2>/dev/null | sed 's/^/  /'
        else
            head -c 400 "$f" | grep -qi '<Keybox' \
                || echo "  ! does not look like a Keybox XML document — the engine drops the profile"
        fi
    else
        echo "keybox      : $kb MISSING/EMPTY ($f) — ConfigStore rejects the whole config"
    fi
done
[ -f "$TEE_DIR/.auto-keybox" ] && echo "keybox mgmt : auto-managed (sha $(cut -c1-12 < "$TEE_DIR/.auto-keybox" 2>/dev/null))"
if [ -f "$TEE_DIR/.keybox-bad" ]; then
    echo "keybox flag : .keybox-bad present (boot validation rejected the live keybox $(date -d @$(cat "$TEE_DIR/.keybox-bad" 2>/dev/null) '+%F %T' 2>/dev/null))"
    [ -f "$TEE_DIR/keybox-bad.log" ] && sed 's/^/  /' "$TEE_DIR/keybox-bad.log" | head -8
fi

head_ "5. engine trace (durable)"
if [ -s "$ELOG" ]; then
    echo "trace : $ELOG ($(wc -c < "$ELOG") bytes, $(wc -l < "$ELOG") lines)"
    echo "  pushes=$(count_pat "$ELOG" 'control: pushed config')" \
         "acks=$(count_pat "$ELOG" 'control: ack')" \
         "staged=$(count_pat "$ELOG" 'cfg: staged profile')" \
         "build-failed=$(count_pat "$ELOG" 'failed to build')" \
         "never-pushed=$(count_pat "$ELOG" 'never pushed a config')"
    echo "  target=1 served=$(count_pat "$ELOG" 'target=1')" \
         "target=0 forwarded=$(count_pat "$ELOG" 'target=0')"
    # The engine's own diagnosis. The C++ side only says "(bad keybox?)"; the Rust
    # TA's keybox parser logs the actual reason, and it is the single most useful
    # line in this whole report when a keybox is unusable.
    _ireason=$(grep -h "teesim_km_init_ex:" "$ELOG" 2>/dev/null | tail -1 | sed 's/.*teesim_km_init_ex: *//')
    if [ -n "$_ireason" ]; then
        echo "  keybox verdict from the engine (teesim_km_init_ex):"
        echo "    $_ireason"
    fi
    echo "-- last ack / staged / failure lines --"
    grep -E "control: ack|cfg: staged profile|failed to build|teesim_km_init_ex|Failed to resolve/push config|No valid config to push" "$ELOG" 2>/dev/null | tail -12
    echo "-- last resolve-side lines --"
    grep -E "Scope\[|config.json invalid|No valid config|pushed config" "$ELOG" 2>/dev/null | tail -8
else
    echo "trace : EMPTY/MISSING ($ELOG)"
    echo "  -> the daemon never got far enough to start LogTail, or it is not"
    echo "     the upstream daemon at all. Fall back to logcat below."
fi

head_ "6. daemon admin endpoint (live)"
if [ -x "$UDS" ] && [ -S "$SOCK_ADMIN" ] && [ -f "$TOKEN" ]; then
    OUT=$("$UDS" "$SOCK_ADMIN" GET /status "$(cat "$TOKEN" 2>/dev/null)" 2>/dev/null)
    if [ -n "$OUT" ]; then
        # v3.2.3 (audit N1): the /status body embeds the full harvest record
        # (plaintext IMEI/MEID/serial — KeyAdmin.kt does o.put("harvest", ...)),
        # so the raw JSON must never reach the terminal. Print only the
        # diagnostic fields the WebUI probe also reads (launcher.js: version,
        # hook); everything else stays behind the admin socket.
        _sf=$(printf '%s\n' "$OUT" | tr '{,}' '\n\n' | grep -E '"(version|hook)"' | head -4)
        if [ -n "$_sf" ]; then
            echo "$_sf"
        else
            echo "status endpoint reachable (fields withheld — /status embeds harvest identifiers)"
        fi
    else
        echo "teesim-uds returned nothing (daemon busy or endpoint moved)"
    fi
    LOGS=$("$UDS" "$SOCK_ADMIN" GET "/logs?after=0&max=200" "$(cat "$TOKEN" 2>/dev/null)" 2>/dev/null)
    [ -n "$LOGS" ] && { echo "-- /logs tail (in-memory ring, survives logcat rotation) --"; echo "$LOGS" | tail -c 2000 | mask_ids; echo; }
else
    echo "skipped: helper/socket/token not all present"
    [ ! -x "$UDS" ] && echo "  helper missing: $UDS (service.sh stages it each boot)"
    [ ! -S "$SOCK_ADMIN" ] && echo "  admin socket missing: $SOCK_ADMIN"
fi

head_ "7. daemon stdout/stderr (crash traces)"
if [ -s "$TEE_DIR/daemon.log" ]; then
    tail -40 "$TEE_DIR/daemon.log" | mask_ids
else
    echo "(empty — the daemon has not written a line to stderr/stdout)"
fi

head_ "8. logcat fallback (last 40 lines, tag TEESimulator)"
logcat -d -s TEESimulator 2>/dev/null | tail -40 | mask_ids

head_ "9. verdict"
# One authority: engine-verdict.sh reads the ack COUNTS (a single-line match
# reports "partial" as if it were through) and records the result for the WebUI.
VSH="$MODDIR/engine-verdict.sh"
if [ -f "$VSH" ]; then
    sh "$VSH" once
    echo
fi
LOGS="$(cat "$ELOG" 2>/dev/null)
$(logcat -d -s TEESimulator 2>/dev/null)"
push_n=$(echo "$LOGS" | grep -c "control: pushed config")
staged_n=$(echo "$LOGS" | grep -c "cfg: staged profile")
build_n=$(echo "$LOGS" | grep -c "failed to build")
never_n=$(echo "$LOGS" | grep -c "never pushed a config")
t1=$(echo "$LOGS" | grep -c "target=1")
t0=$(echo "$LOGS" | grep -c "target=0")
if [ "$staged_n" -gt 0 ] && [ "$t1" -gt 0 ]; then
    echo "OK  : engine is live — $staged_n staged profile(s), $t1 request(s) served by the engine"
elif [ "$staged_n" -gt 0 ]; then
    echo "WARN: config reached the interceptor ($staged_n staged) but 0 requests matched"
    echo "      -> profile apps/uids do not line up with the real callers"
    echo "         served=$t1 forwarded=$t0"
elif [ "$never_n" -gt 0 ] || [ "$t0" -gt 0 ]; then
    echo "FAIL: the engine is NOT serving — every request falls through to the real HAL"
    if [ "$build_n" -gt 0 ]; then
        echo "      cause: the interceptor rejected profile(s) it could not build:"
        echo "$LOGS" | grep "failed to build" | tail -3
        echo "      -> the keybox cannot be used by the engine. The reason is printed"
        echo "         above as a teesim_km_init_ex line; swap the keybox with"
        echo "         'sh $MODDIR/keybox-swap.sh --auto <a.xml> <b.xml>' (it reads the"
        echo "         engine's answer for each candidate) and re-run this script."
    elif [ "$push_n" -eq 0 ]; then
        echo "      cause: the daemon never pushed a config (pushes=0). See section 9's"
        echo "             daemon.log for the resolve/push exception, or a silent crash."
    else
        echo "      cause: pushed=$push_n but staged=0 — the push never completed on the"
        echo "             wire. Check CTL_SOCK and the control: connection error lines."
    fi
elif [ "$push_n" -gt 0 ]; then
    echo "WARN: pushed=$push_n but no staged/never-pushed marker found — buffer rotated."
    echo "      Re-run within a minute of a reboot to catch the verdict lines."
else
    echo "??  : no verdict line found — neither the durable trace nor logcat has one."
    echo "      Reboot and re-run this script within a minute of boot."
fi

echo
echo "== done =="
