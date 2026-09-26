#!/system/bin/sh
# Aegis Fusion — community keybox auto-fetch & scheduled refresh.
#
# v2.2.8: MULTIPLE SOURCES. The channel ecosystem rotates as Google revokes, so
# one dead channel must not take STRONG integrity down with it. Sources are
# tried in order until one yields a valid keybox; the winner is recorded in
# .keybox-source and — when the source publishes one — its status file is
# fetched and PAIRED to the keybox it actually supplied (mixing a status file
# from channel A with a keybox from channel B is exactly the misleading-display
# bug this guards against).
#
# Built-ins:
#   Megatron — MeowDump/MeowDump (b64 x10 -> hex -> ROT13). Primary; the only
#              one with a community status file. Adapted from
#              MeowDump/Integrity-Box (webroot/common_scripts/key.sh).
#   Yurikey  — Yurii0307/yurikey "key" (single base64).
#   KOWX712  — KOWX712/Tricky-Addon-Update-Target-List "keybox" branch ".extra"
#              (hex -> base64). The upstream addon empties this file between
#              rotations, so it is a fallback, never a primary.
# Users can prepend their own channels via /data/adb/teesim/keybox-sources.conf,
# one per line:  name|url|format[|status_url[|sha256]]
#   format: b64 (single base64) | hexb64 (hex then base64) |
#           megatron (b64 x10, hex, ROT13) | raw (plain keybox.xml)
#   sha256: optional integrity pin — a channel whose payload does not hash to
#           this value is rejected BEFORE deployment (defence against a
#           compromised or hostile channel serving a well-formed keybox).
# Lines starting with '#' are ignored.
#
# Fusion differences vs Integrity-Box: we deploy to the TEESimulator path only,
# keep a small rolling backup, record validity from the winning source's
# key-status file, and NEVER overwrite a user-imported keybox (detected by hash
# mismatch against our marker file).

MODPATH="${0%/*}"
# --force: manual fetch from the WebUI ("手动获取"). Overrides the user-imported
# stand-down — the user explicitly asked to take over the deployed keybox from
# the preferred channel; the original file is kept in the rolling backup and
# the result is adopted as auto-managed (marker written either way).
FORCE=0
REVCHECK_ONLY=0
[ "$1" = "--force" ] && FORCE=1
[ "$1" = "--revcheck" ] && REVCHECK_ONLY=1
# Overridable like pif-fetch.sh: the test harness (and any relocated tree)
# must be able to point the whole fetcher at a throwaway directory. The
# helpers below already honour AEGIS_TEE_DIR — the main script has to too,
# or the override is a lie (seen live: the harness silently operated on the
# real /data/adb/teesim and hung on real network fetches).
TEE_DIR="${AEGIS_TEE_DIR:-/data/adb/teesim}"
KEYBOX="$TEE_DIR/keybox.xml"
MARKER="$TEE_DIR/.auto-keybox"        # sha256 of the last keybox we installed
SOURCES_CONF="$TEE_DIR/keybox-sources.conf"
SRC_FILE="$TEE_DIR/.keybox-source"    # name of the channel the current keybox came from
STATUS_TXT="$TEE_DIR/key-status.txt"  # raw upstream validity string (of THIS keybox's channel)
STATUS_N="$TEE_DIR/.key-status-n"     # number of green circles (3 / 2 / 0 / -1 unknown)
REVJSON="$TEE_DIR/.revocation-status.json" # Google's official attestation revocation list (cached)
LOG="$TEE_DIR/keybox-fetch.log"
BACKUP_DIR="$TEE_DIR/keybox-backups"

URL="https://raw.githubusercontent.com/MeowDump/MeowDump/refs/heads/main/Megatron"
YURIKEY_URL="https://raw.githubusercontent.com/Yurii0307/yurikey/main/key"
KOW_URL="https://raw.githubusercontent.com/KOWX712/Tricky-Addon-Update-Target-List/keybox/.extra"
STATUS_URL="https://raw.githubusercontent.com/MeowDump/Integrity-Box/refs/heads/main/keybox/key-status"

# Temp dir lives UNDER TEE_DIR (root-only 0700), never /data/local/tmp: a
# world-writable stage with a predictable name would let a shell-uid process
# pre-plant symlinks that this root script would follow with `> "$file"`
# (root arbitrary-file-write). Inside TEE_DIR the parent is ours alone.
TMPD="$TEE_DIR/.tmp.$$"
mkdir -p "$TEE_DIR" "$BACKUP_DIR" "$TMPD" || exit 1
trap 'rm -rf "$TMPD"' EXIT

# The helpers we shell out to (engine-verdict.sh, keybox-check.sh) honour the
# AEGIS_TEE_DIR / AEGIS_MODDIR overrides, so propagate ours: the paths then stay
# consistent even when the whole tree is relocated (tests, a second install).
AEGIS_TEE_DIR="$TEE_DIR"
export AEGIS_TEE_DIR

# Logging first: the concurrency guard below already logs, and this file used to
# define log()/dbg() further down, so every run printed "dbg: command not found"
# to stderr on the line after taking the lock (harmless but it lands in whatever
# captured stderr — the WebUI's fetch output, the installer log).
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Debug channel (v3.0.2): while /data/adb/teesim/.debug exists (default ON
# since flash; toggled from the logs page), verbose step-by-step lines go to
# the unified debug.log. The flag is checked per call so a toggle takes
# effect without restarting anything.
DBG_LOG="$TEE_DIR/debug.log"
dbg() { [ -f "$TEE_DIR/.debug" ] && echo "[$(date '+%F %T')] [kbfetch] $*" >> "$DBG_LOG"; return 0; }

# Concurrency guard: a fetch takes 30s+ with the network in the way. Overlapping
# runs race on keybox.xml — the WebUI polls this lock to show "后台刷新中", and
# every launcher (WebUI button, cron, service.sh) gets mutual exclusion for free.
# mkdir is atomic even on toybox.
LOCK="$TEE_DIR/.kb-fetching.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    # Stale lock: reap immediately when the recorded holder is dead (kill -9
    # mid-fetch), or as a 15-min backstop when the holder is alive but stuck.
    now=$(date +%s)
    lmt=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)
    holder=$(cat "$LOCK/holder" 2>/dev/null)
    dead=1
    case "$holder" in
        ''|*[!0-9]*) ;;                        # no/invalid pid -> fall back to age
        *) kill -0 "$holder" 2>/dev/null && dead=0 ;;
    esac
    if [ "$dead" = 0 ] && [ "$((now - lmt))" -lt 900 ]; then
        log "fetch already running; skipping"
        exit 75
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || exit 75
fi
echo $$ > "$LOCK/holder" 2>/dev/null
dbg "lock acquired by pid $$"

# ---------- live progress ("后台刷新中" must say WHAT it is doing) ----------
# A fetch legitimately takes minutes: 3 attempts x 45s timeout x N channels, plus
# the engine handshake. The WebUI used to show a bare "后台刷新中…" for that whole
# window, which is indistinguishable from a hang — a field report read exactly
# that way ("刚开始显示后台刷新中一直不更新"). One line, rewritten in place, so the
# panel can show the stage, the channel and how long it has been going.
PROG="$TEE_DIR/.kb-fetch.progress"
trap 'rm -rf "$TMPD" "$LOCK"; rm -f "$PROG"' EXIT
progress() {
    printf '%s\n%s\n%s\n' "$(date +%s)" "${1:-}" "${2:-}" > "$PROG.tmp" 2>/dev/null \
        && mv -f "$PROG.tmp" "$PROG" 2>/dev/null
    chmod 0644 "$PROG" 2>/dev/null
    return 0
}
SRC_NOW=""
progress "启动" "读取 Google 吊销名单缓存"

# "上次刷新" timestamp — written on EVERY successful fetch pass (updated,
# unchanged, adopted). The WebUI used to derive the age from keybox.xml's
# mtime, which never moves on a hash-match pass, so the panel kept showing a
# stale "距上次刷新 N 小时" after a manual fetch (v3.0.2 field report).
FETCH_TS="$TEE_DIR/.kb-last-fetch"
touch_fetch_ts() { date +%s > "$FETCH_TS" 2>/dev/null; return 0; }

trim_log() {
    [ -s "$LOG" ] || return 0
    lines=$(wc -l < "$LOG" | tr -d ' ')
    if [ "$lines" -gt 400 ]; then
        tail -n 200 "$LOG" > "$TMPD/log" && mv -f "$TMPD/log" "$LOG"
    fi
}

sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Android ships neither curl nor wget. Root managers always ship a full busybox
# (KernelSU: /data/adb/ksu/bin/busybox, APatch: /data/adb/ap/bin/busybox,
# Magisk: /data/adb/magisk/busybox) whose wget handles https.
BB=""
for b in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox "$(command -v busybox 2>/dev/null)"; do
    if [ -n "$b" ] && [ -x "$b" ]; then
        BB="$b"
        break
    fi
done

if command -v curl >/dev/null 2>&1; then
    DL="curl"
elif command -v wget >/dev/null 2>&1; then
    DL="wget"
elif [ -n "$BB" ] && "$BB" wget --help >/dev/null 2>&1; then
    DL="busybox"
else
    DL="none"
fi

# ---------- proxy passthrough + auto-probe + direct-IP ladder (v3.2.2) ----------
# Same contract as pif-fetch.sh: $TEE_DIR/pif-proxy.conf (first line, a local
# proxy URL) is honoured, and when direct downloads fail with NO proxy
# configured, the common local proxy ports are probed ONCE per run and the
# winner is remembered in $TEE_DIR/pif-proxy.auto — the SAME files pif-fetch
# uses, so one configuration serves both fetchers. Without this, every
# keybox-fetch endpoint (all raw.githubusercontent.com) is unreachable on a
# censored network and auto refresh silently fails forever (seen live
# 2026-09-13: last successful deploy froze at yesterday 14:00, "上次刷新 —").
# Full download ladder per URL: direct retry x3 -> configured/remembered/
# probed local proxy -> curl --resolve pinned Fastly IP (phase 4, see fetch).
# Env knobs AEGIS_KB_PROXY / AEGIS_KB_AUTOPROXY / AEGIS_KB_PROBE /
# AEGIS_KB_PROBE_PORTS / AEGIS_KB_DIRECTIP / AEGIS_KB_IPS exist for the test
# harness. POSIX arithmetic only.
KB_PX=""
KB_PX_SRC=""
KB_PX_RESOLVED=0
KB_PROBED=0
kb_proxy_resolve() {
    KB_PX_RESOLVED=1
    if [ -n "$AEGIS_KB_PROXY" ]; then
        KB_PX="$AEGIS_KB_PROXY"
        KB_PX_SRC="env"
        return 0
    fi
    if [ -s "$TEE_DIR/pif-proxy.conf" ]; then
        KB_PX="$(head -n 1 "$TEE_DIR/pif-proxy.conf" 2>/dev/null | tr -d ' \t\r\n')"
        # The conf is hostile input (world-readable path, root consumer):
        # accept only a conservative URL/host:port charset.
        case "$KB_PX" in
            *[!A-Za-z0-9:._@/-]*)
                KB_PX=""
                log "WARNING: pif-proxy.conf rejected (unsafe characters in the proxy value)"
                ;;
        esac
        [ -n "$KB_PX" ] && KB_PX_SRC="conf"
    fi
    # Third source: the remembered auto-proxy from a previous run (pif-fetch
    # reads this file too — mirror it exactly, otherwise the memory is
    # write-only and every failing run re-probes all ports from scratch,
    # and the stale-drop branch below can never fire).
    if [ -z "$KB_PX" ] && [ -s "$TEE_DIR/pif-proxy.auto" ]; then
        KB_PX="$(head -n 1 "$TEE_DIR/pif-proxy.auto" 2>/dev/null | tr -d ' \t\r\n')"
        case "$KB_PX" in
            *[!A-Za-z0-9:._@/-]*) KB_PX="" ;;
        esac
        [ -n "$KB_PX" ] && KB_PX_SRC="auto"
    fi
}
kb_probe_port() {
    if [ -n "$AEGIS_KB_PROBE" ]; then
        sh "$AEGIS_KB_PROBE" "$1" >/dev/null 2>&1
        return $?
    fi
    command -v wget >/dev/null 2>&1 || return 1
    _kp_t=""
    command -v timeout >/dev/null 2>&1 && _kp_t="timeout 8"
    ( export http_proxy="http://127.0.0.1:$1" https_proxy="http://127.0.0.1:$1"
      # v3.2.3 (audit L2): probe against GitHub itself, not a third-party search
      # domain. The request leaves the device through the candidate proxy, so
      # aim it at the exact infrastructure the fetches need; robots.txt answers
      # 200 unauthenticated. No device data in the request.
      # v3.2.3 (audit N9): full GET, NOT --spider — busybox wget cannot do
      # --spider (see harden-pif N4), which made the auto-proxy probe fail
      # forever on those devices.
      $_kp_t wget -q -T 8 -O /dev/null https://github.com/robots.txt ) 2>/dev/null
}

# fetch <url> <outfile> — 3 attempts with backoff. Each attempt is hard-capped
# by toybox `timeout`: busybox wget's -T does not cover DNS resolution, and a
# blackholed route (observed in the field: a revocation refresh hung 16+ min
# with no data flowing) would otherwise hold the fetch lock indefinitely.
TO=""; TOSEC=""; command -v timeout >/dev/null 2>&1 && { TO="timeout 45"; TOSEC=45; }
fetch() {
    _u="$1"; _o="$2"
    dbg "download start: ${_u%%/*}/… downloader=$DL timeout=${TOSEC:-none}"
    [ "$DL" != "none" ] || { dbg "no usable downloader on this device"; return 1; }
    [ "$KB_PX_RESOLVED" = "1" ] || kb_proxy_resolve
    while :; do
        if [ -n "$KB_PX" ]; then
            export http_proxy="$KB_PX" https_proxy="$KB_PX"
            dbg "download via proxy $KB_PX ($KB_PX_SRC)"
        fi
        _n=0
        _ok=0
        while [ "$_n" -lt 3 ]; do
            _n=$((_n + 1))
            progress "下载候选" "${SRC_NOW:-候选源} · 第 $_n/3 次尝试"
            case "$DL" in
                curl)    $TO curl -fsSL --connect-timeout 15 --max-time 120 "$_u" -o "$_o" 2>/dev/null ;;
                wget)    $TO wget -q -T 15 -O "$_o" "$_u" 2>/dev/null ;;
                busybox) $TO "$BB" wget -q -T 15 -O "$_o" "$_u" 2>/dev/null ;;
            esac
            _rc=$?
            [ -s "$_o" ] && { dbg "download ok: attempt $_n, $(wc -c < "$_o" | tr -d ' ') bytes"; _ok=1; break; }
            if [ "$_rc" = "0" ]; then
                # The downloader succeeded and wrote nothing (usually an empty 200 body).
                # Logging it as "download failed: rc=0" reads like a contradiction and
                # cost a field-debug round: the interesting fact is that the SERVER sent
                # no data, not that the tool reported success.
                dbg "download empty: attempt $_n (downloader rc=0, server sent 0 bytes)"
            else
                dbg "download failed: attempt $_n rc=$_rc"
            fi
            sleep "$_n"
        done
        unset http_proxy https_proxy
        [ "$_ok" = "1" ] && return 0
        # All attempts through a REMEMBERED auto proxy failed: drop it so the
        # next run re-probes instead of retrying a corpse (VPN off, port moved).
        if [ -n "$KB_PX" ] && [ "$KB_PX_SRC" = "auto" ]; then
            rm -f "$TEE_DIR/pif-proxy.auto" 2>/dev/null
            log "remembered proxy did not work; dropped pif-proxy.auto (will re-probe next run)"
            KB_PX=""
            KB_PX_SRC=""
        fi
        # One auto-probe per run, only when nothing is configured (same
        # semantics as pif-fetch: healthy direct networks never pay for it).
        if [ "$KB_PROBED" = "0" ] && [ -z "$KB_PX" ] && [ "${AEGIS_KB_AUTOPROXY:-1}" = "1" ]; then
            KB_PROBED=1
            _kp=""
            for _p in ${AEGIS_KB_PROBE_PORTS:-7890 7897 10808 10809 2334 2080}; do
                case "$_p" in *[!0-9]*) continue ;; esac
                if kb_probe_port "$_p"; then _kp="http://127.0.0.1:$_p"; break; fi
            done
            if [ -n "$_kp" ]; then
                KB_PX="$_kp"
                KB_PX_SRC="auto"
                echo "$KB_PX" > "$TEE_DIR/pif-proxy.auto" 2>/dev/null
                log "auto-proxy: found a working local proxy at $KB_PX; retrying downloads through it"
                continue
            fi
        fi
        # Last resort (phase 4): pin raw.githubusercontent.com to its Fastly
        # anycast IPs, bypassing poisoned DNS entirely. curl-only — busybox
        # wget has no --resolve. TLS stays fully verified: SNI and Host are
        # unchanged, so the real certificate must still validate (this is the
        # safe replacement for Integrity-Box's --insecure shortcut). Zero
        # system mutation: unlike a setprop DNS override, nothing here touches
        # device state. Endpoints only ever resolve to Fastly, so the IP list
        # is not spoofable by a hostile DNS in the first place.
        if [ "$DL" = "curl" ] && [ "${AEGIS_KB_DIRECTIP:-1}" = "1" ]; then
            case "$_u" in
                https://raw.githubusercontent.com/*)
                    for _ip in ${AEGIS_KB_IPS:-185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133}; do
                        case "$_ip" in *[!0-9.]*) continue ;; esac
                        progress "下载候选" "${SRC_NOW:-候选源} · 直连 CDN $_ip"
                        $TO curl -fsSL --connect-timeout 10 --max-time 90 \
                            --resolve "raw.githubusercontent.com:443:$_ip" "$_u" -o "$_o" 2>/dev/null
                        _rc=$?
                        [ -s "$_o" ] && { dbg "download ok: direct-IP $_ip, $(wc -c < "$_o" | tr -d ' ') bytes"; return 0; }
                        dbg "download failed: direct-IP $_ip rc=$_rc"
                    done
                    ;;
            esac
        fi
        return 1
    done
}

# b64decode <in> <out> — toybox base64, busybox fallback
b64decode() {
    if base64 -d "$1" > "$2" 2>/dev/null; then return 0; fi
    [ -n "$BB" ] && "$BB" base64 -d "$1" > "$2" 2>/dev/null
}

# hexdecode <in> <out> — strip everything that is not a hex digit first (the
# KOWX712 upstream .extra may carry separators), then toybox/busybox xxd.
hexdecode() {
    tr -cd '0-9A-Fa-f' < "$1" > "$TMPD/hex.clean" 2>/dev/null || return 1
    if xxd -r -p "$TMPD/hex.clean" > "$2" 2>/dev/null; then return 0; fi
    if [ -n "$BB" ] && "$BB" xxd -r -p "$TMPD/hex.clean" > "$2" 2>/dev/null; then return 0; fi
    return 1
}

# decode_payload <raw-file> <out-file> <format>
decode_payload() {
    _r="$1"; _o="$2"; _f="$3"
    case "$_f" in
        raw)
            cat "$_r" > "$_o" 2>/dev/null
            ;;
        b64)
            b64decode "$_r" "$_o"
            ;;
        hexb64)
            hexdecode "$_r" "$TMPD/hb.mid" && b64decode "$TMPD/hb.mid" "$_o"
            ;;
        megatron)
            _cur="$_r"; _i=0
            while [ "$_i" -lt 10 ]; do
                _nxt="$TMPD/mg.$_i"
                if ! b64decode "$_cur" "$_nxt"; then
                    return 1
                fi
                [ "$_cur" != "$_r" ] && rm -f "$_cur"
                _cur="$_nxt"
                _i=$((_i + 1))
            done
            hexdecode "$_cur" "$TMPD/mg.hex" && \
                tr 'A-Za-z' 'N-ZA-Mn-za-m' < "$TMPD/mg.hex" > "$_o" 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

valid_keybox() {
    # Structural validation, shared with the installer / boot check / health
    # report. The old body here was two greps ("<Keybox" + "PrivateKey"), which a
    # keybox can satisfy while still being unusable by the engine: a <Key> with
    # no algorithm attribute, or a chain carrying a single certificate (the TA
    # requires at least 2). Deploying such a keybox silently costs EVERY
    # profile — the engine logs "keymint: profile <id> failed to build (bad
    # keybox?)", drops them all, and the device sits at one-green while every
    # other indicator looks healthy.
    _kbc="${0%/*}/keybox-check.sh"
    if [ -f "$_kbc" ]; then
        sh "$_kbc" "$1" --quiet >/dev/null 2>&1
    else
        grep -q "<Keybox" "$1" 2>/dev/null && grep -q "PrivateKey" "$1" 2>/dev/null
    fi
}

# try_source <name> <url> <format> [sha256-pin] — on success leaves the decoded
# keybox in $NEW and returns 0. The optional pin is a literal full-hex sha256
# the payload MUST hash to; a mismatch rejects the source before anything is
# deployed (case-insensitive, whitespace tolerated).
try_source() {
    _name="$1"; _url="$2"; _fmt="$3"; _pin="$4"
    SRC_NOW="$_name"
    log "trying source: $_name"
    progress "下载候选" "$_name · 准备"
    if ! fetch "$_url" "$TMPD/src.raw"; then
        log "source $_name: download failed (downloader: $DL; network?)"
        return 1
    fi
    progress "解析候选" "$_name · 格式 $_fmt"
    if ! decode_payload "$TMPD/src.raw" "$NEW" "$_fmt"; then
        log "source $_name: decode failed (format: $_fmt)"
        rm -f "$NEW"
        return 1
    fi
    if ! valid_keybox "$NEW"; then
        # e.g. the KOWX712 mirror is emptied between community rotations —
        # treat as unavailable and fall through to the next source.
        log "source $_name: payload is not a keybox (empty or rotated out?)"
        rm -f "$NEW"
        return 1
    fi
    if [ -n "$_pin" ]; then
        _pin=$(printf '%s' "$_pin" | tr -d ' \r\n\t' | tr 'A-Z' 'a-z')
        _got=$(sha "$NEW")
        if [ "$_got" != "$_pin" ]; then
            log "source $_name: sha256 pin MISMATCH (want ${_pin:-?}, got ${_got:-none}); rejected"
            rm -f "$NEW"
            return 1
        fi
        log "source $_name: sha256 pin verified"
    fi
    log "source $_name: got a valid keybox"
    return 0
}

# ---------- deploy + verify: the engine is the only authority ----------
# A structurally valid keybox can still be one the engine refuses (a single-cert
# chain, an EC key that is not P-256, a truncated base64 body the C++ side never
# parses). v3.1.2 and earlier deployed the first source that passed the
# structural check and never asked the engine — which is how a box that made the
# module show "three greens" could leave the device at one green. So: deploy,
# then READ THE ACK (engine-verdict.sh parses the ack counts and pulls the
# engine's own reason out of teesim_km_init_ex).
VERDICT_SH="${0%/*}/engine-verdict.sh"
BADLIST="$TEE_DIR/.keybox-bad-payloads"   # sha256 of payloads the engine refused

log_size() {
    s=$(wc -c < "$TEE_DIR/log/teesim.log" 2>/dev/null)
    [ -n "$s" ] || s=0
    echo "$s"
}

# Can a verdict be obtained at all? Only if the daemon is up AND the engine has
# already completed at least one push/ack cycle on this boot — otherwise a
# perfectly good keybox would be "rejected" for the crime of being deployed
# before the engine was listening. When this fails we fail OPEN (deploy, no
# verdict), which is the pre-v3.1.3 behaviour.
engine_verifiable() {
    [ -f "$VERDICT_SH" ] || return 1
    [ -n "$(pidof teesim 2>/dev/null)" ] || return 1
    grep -q "control: ack" "$TEE_DIR/log/teesim.log" 2>/dev/null && return 0
    # Logcat-dead devices: the durable trace never fills, but the daemon exposes
    # its in-memory push/ack state over the admin socket (patch 0007) - verdicts
    # are possible there too.
    sh "$VERDICT_SH" socket-live >/dev/null 2>&1
}

engine_reason() {
    [ -f "$VERDICT_SH" ] && sh "$VERDICT_SH" reason 2>/dev/null
    return 0
}

# client_recycle — the only part of the old bounce that was worth keeping.
# The daemon re-pushes on the FileObserver event and re-attests the target apps'
# keys itself when the lib acks (Control.kt:209-227 -> ReAttest.run), so nothing
# here may kill the daemon or keystore2 — that interrupted the daemon's own
# re-attest pass and is what made a swap take 30s+ instead of ~1s. A cached
# DroidGuard session, however, keeps attesting with the old chain until it is
# recycled (adapted from AlwaysStrong), so the CLIENT side still needs a nudge.
client_recycle() {
    dg_pid=$(pidof com.google.android.gms.unstable 2>/dev/null)
    if [ -n "$dg_pid" ]; then
        kill "$dg_pid" 2>/dev/null
        log "DroidGuard (gms.unstable) recycled so the new chain is used"
    fi
    am force-stop com.android.vending >/dev/null 2>&1 \
        && log "Play Store force-stopped"
    return 0
}

# deploy_atomic <file> — cp into the SAME directory then rename: the watcher sees
# MOVED_TO. A plain cp onto a symlinked keybox.xml would rewrite the link TARGET
# (e.g. TrickyStore's own copy) instead of replacing the link.
deploy_atomic() {
    cp -f "$1" "$KEYBOX.new" 2>/dev/null || return 1
    mv -f "$KEYBOX.new" "$KEYBOX" 2>/dev/null || return 1
    chmod 0600 "$KEYBOX" 2>/dev/null
    return 0
}

bad_payload() {
    grep -qx "$1" "$BADLIST" 2>/dev/null
}

remember_bad() {
    _h="$1"
    touch "$BADLIST" 2>/dev/null
    grep -qx "$_h" "$BADLIST" 2>/dev/null || echo "$_h" >> "$BADLIST"
    # bounded: a community rotation always produces a new hash anyway
    if [ "$(wc -l < "$BADLIST" 2>/dev/null)" -gt 20 ]; then
        tail -n 20 "$BADLIST" > "$TMPD/badlist" && mv -f "$TMPD/badlist" "$BADLIST"
    fi
    chmod 0600 "$BADLIST" 2>/dev/null
    return 0
}

# deploy_and_verify <file> <source-name> — 0 only when the ENGINE accepts.
# The failures worth distinguishing are logged with the engine's own words.
deploy_and_verify() {
    _f="$1"; _src="$2"
    _mark=$(log_size)
    if ! deploy_atomic "$_f"; then
        log "ERROR: failed to write $KEYBOX"
        return 2
    fi
    log "deployed payload from $_src ($(wc -c < "$KEYBOX" | tr -d ' ') bytes); waiting for the engine's ack"
    progress "等引擎应答" "$_src · 最多 10 秒"
    if ! engine_verifiable; then
        log "no live engine to ask (daemon down or no ack history yet) — deployed WITHOUT a verdict"
        return 0
    fi
    sh "$VERDICT_SH" watch 10 "$_mark" >> "$LOG" 2>&1
    _rc=$?
    if [ "$_rc" = 2 ]; then
        # Logcat-dead devices: the trace never fills (see engine-verdict `once`).
        # The daemon re-pushes on the deploy's FileObserver event; poll `once` -
        # whose socket fallback reads the daemon's in-memory state - a few times
        # instead of shipping without a verdict.
        _try=0
        while [ "$_try" -lt 3 ]; do
            sleep 2
            sh "$VERDICT_SH" once >> "$LOG" 2>&1
            _rc=$?
            [ "$_rc" = 2 ] || break
            _try=$((_try + 1))
        done
    fi
    case "$_rc" in
        0)  log "engine ACCEPTED the payload from $_src"; return 0 ;;
        1)  _why=$(engine_reason)
            log "engine REJECTED the payload from $_src: ${_why:-no reason given}"
            return 1 ;;
        *)  log "engine did not answer within 10s (silent) — keeping the payload, no verdict"
            return 0 ;;
    esac
}

trim_log

dbg "run start: force=$FORCE revcheck=$REVCHECK_ONLY downloader=$DL"

# ---------- Google attestation revocation cache (v2.2.9) ----------
# The community key-status files lag behind reality (the WebUI used to show
# 🟢🟢🟢 while PIAC only passed BASIC), and they say nothing about a
# user-imported keybox. Google publishes the authoritative per-key revocation
# list at this URL — keys are certificate serial numbers in lowercase hex.
# We cache it hourly; the WebUI then compares the DEPLOYED keybox's chain
# serials against it locally (no extra network, works for imported boxes).
# Runs BEFORE the user-import guard so imported boxes get real detection too,
# and as `--revcheck` (hourly from service.sh) even when auto-refresh is off.
REV_STATUS_URL="https://android.googleapis.com/attestation/status"
rev_cache_refresh() {
    _now=$(date +%s)
    _mt=$(stat -c %Y "$REVJSON" 2>/dev/null || echo 0)
    if [ -s "$REVJSON" ] && [ "$((_now - _mt))" -lt 3600 ]; then
        return 0
    fi
    log "refreshing Google attestation revocation status cache"
    if fetch "$REV_STATUS_URL" "$REVJSON.tmp" && grep -q '"entries"' "$REVJSON.tmp" 2>/dev/null; then
        mv -f "$REVJSON.tmp" "$REVJSON"
        log "revocation cache updated ($(wc -c < "$REVJSON" | tr -d ' ') bytes)"
    else
        rm -f "$REVJSON.tmp"
        log "revocation cache refresh failed (keeping previous)"
        return 1
    fi
}
rev_cache_refresh
dbg "revocation cache refresh rc=$? (list at $REVJSON)"
if [ "$REVCHECK_ONLY" = "1" ]; then
    dbg "revcheck-only run, exiting here"
    exit 0
fi

# ---------- guards: a user-imported keybox is never touched ----------
# Checked before any network work: while a user keybox is deployed, no channel
# status is refreshed either — the community status says nothing about it and
# the WebUI displays it as reference-only. --force (手动获取) bypasses this
# deliberately: that button IS the recovery path for a dead imported keybox.
#
# An import is detected two ways: (a) deployed hash differs from the marker,
# (b) keybox.xml is strictly newer than the marker — the user overwrote the
# file with content identical to the channel box (same community key), which
# hash comparison alone cannot see. Either way the write itself is a CLOSE_WRITE/
# MOVED_TO on a watched path, so the daemon re-reads and re-pushes on its own —
# nothing here kills anything. Only the client session is recycled, ONCE per
# imported file (recorded in .imported-bounced; the hourly tick would otherwise
# recycle forever).
if [ "$FORCE" != "1" ] && [ -s "$KEYBOX" ]; then
    cur_hash=$(sha "$KEYBOX")
    kbtm=$(stat -c %Y "$KEYBOX" 2>/dev/null || echo 0)
    kbmm=$(stat -c %Y "$MARKER" 2>/dev/null || echo 0)
    imported=no
    # Edge (audit 2026-09-15, accepted): hash == marker AND kbtm <= kbmm means
    # the current file is byte-identical to the last channel deploy — rotation
    # replacing it loses nothing user-owned, so it is correctly NOT "imported".
    if [ ! -f "$MARKER" ] || [ "$cur_hash" != "$(cat "$MARKER" 2>/dev/null)" ]; then
        imported=yes
    elif [ "$kbtm" -gt 0 ] && [ "$kbmm" -gt 0 ] && [ "$kbtm" -gt "$kbmm" ]; then
        imported=yes
    fi
    if [ "$imported" = "yes" ]; then
        if [ "$(cat "$TEE_DIR/.imported-bounced" 2>/dev/null)" = "$cur_hash" ]; then
            log "user-imported keybox detected; auto-refresh skipped"
            dbg "import guard: already handled this file, standing down"
        else
            echo "$cur_hash" > "$TEE_DIR/.imported-bounced" 2>/dev/null
            log "user-imported keybox detected; the daemon re-reads it on its own (no reboot needed)"
            dbg "import guard: deployed sha=$cur_hash marker=$(cat "$MARKER" 2>/dev/null || echo none) — client recycle only"
            # The overwrite itself was a CLOSE_WRITE/MOVED_TO on a watched path,
            # so the daemon has already re-read and re-pushed it. Nothing needs
            # killing; only the client's cached DroidGuard session needs a nudge.
            client_recycle
        fi
        exit 0
    fi
fi
if [ "$FORCE" = "1" ] && [ -s "$KEYBOX" ]; then
    # v3.2.3 (audit M11): make the "backup kept" promise REAL. The old code only
    # copied payloads the engine REJECTED (the wrong bytes) and deleted the
    # pre-snapshot on success — a manual fetch destroyed a user-imported keybox
    # with no copy anywhere. Back up the CURRENT bytes first; if the backup
    # cannot be written, abort instead of destroying data we cannot restore.
    _ts=$(date +%Y%m%d-%H%M%S)
    if cp -fL "$KEYBOX" "$BACKUP_DIR/keybox_pre-force_$_ts.xml" 2>/dev/null; then
        chmod 0600 "$BACKUP_DIR/keybox_pre-force_$_ts.xml" 2>/dev/null
        log "manual fetch (--force): backed up the current keybox -> $BACKUP_DIR/keybox_pre-force_$_ts.xml"
        # keep the 5 most recent pre-force backups
        ls -1t "$BACKUP_DIR"/keybox_pre-force_*.xml 2>/dev/null | tail -n +6 | while read -r old; do
            rm -f "$old" 2>/dev/null
        done
    else
        log "manual fetch (--force): WARNING could not back up the current keybox — aborting, nothing was replaced"
        exit 1
    fi
    log "manual fetch (--force): replacing the deployed keybox from the preferred channel"
fi

# ---------- build the source list: preferred source first, then user channels, then built-ins ----------
# The WebUI's channel chips write the preferred name to keybox-source-pref
# (empty/absent = automatic order). The preferred channel is tried FIRST;
# if it fails the rest still run in default order — a stale or dead preference
# must never break the supply chain.
PREF=""
if [ -f "$TEE_DIR/keybox-source-pref" ]; then
    PREF=$(head -n 1 "$TEE_DIR/keybox-source-pref" 2>/dev/null | tr -d ' \r\n')
fi

: > "$TMPD/sources"
if [ -f "$SOURCES_CONF" ]; then
    while IFS='|' read -r u_name u_url u_fmt u_status u_pin _junk; do
        case "$u_name" in ''|'#'*) continue ;; esac
        case "$u_fmt" in b64|hexb64|megatron|raw) ;; *) continue ;; esac
        [ -n "$u_url" ] || continue
        printf '%s|%s|%s|%s|%s\n' "$u_name" "$u_url" "$u_fmt" "${u_status:-}" "${u_pin:-}" >> "$TMPD/sources"
    done < "$SOURCES_CONF"
fi
printf 'Megatron|%s|megatron|%s|\n' "$URL" "$STATUS_URL" >> "$TMPD/sources"
printf 'Yurikey|%s|b64||\n' "$YURIKEY_URL" >> "$TMPD/sources"
printf 'KOWX712|%s|hexb64||\n' "$KOW_URL" >> "$TMPD/sources"

if [ -n "$PREF" ]; then
    # Literal prefix match (name + separator) — no regex from user input.
    awk -v p="$PREF" 'index($0, p "|") == 1' "$TMPD/sources" > "$TMPD/sources.reordered" 2>/dev/null || : > "$TMPD/sources.reordered"
    awk -v p="$PREF" 'index($0, p "|") != 1' "$TMPD/sources" >> "$TMPD/sources.reordered" 2>/dev/null || true
    [ -s "$TMPD/sources.reordered" ] && mv -f "$TMPD/sources.reordered" "$TMPD/sources"
    log "preferred source: $PREF"
fi

# ---------- walk the sources: the first one the ENGINE accepts wins ----------
# The structural check in try_source() is necessary but not sufficient — only the
# TA decides. So each candidate is deployed and then judged by the engine; a
# refusal is remembered by payload hash (so the hourly tick does not re-try a
# known-dead box) and the next source is tried. The keybox deployed when this run
# started is snapshotted first, so a run in which NOTHING is accepted can put the
# device back exactly as it found it.
NEW="$TMPD/keybox.xml"
WON=""
WON_STATUS=""
PRE="$TEE_DIR/.keybox.prerun.xml"
rm -f "$PRE"
[ -s "$KEYBOX" ] && cp -fL "$KEYBOX" "$PRE" 2>/dev/null
CUR_HASH=""
[ -s "$KEYBOX" ] && CUR_HASH=$(sha "$KEYBOX")

# What does the engine say about what is deployed RIGHT NOW? If it already
# refused this payload, a hash match must NOT count as "nothing to do" — that is
# exactly the state a bad auto-fetched box leaves behind, and the old code would
# sit in it forever.
CUR_REJECTED=no
if [ -s "$KEYBOX" ] && engine_verifiable; then
    sh "$VERDICT_SH" once >/dev/null 2>&1 || CUR_REJECTED=yes
    [ "$CUR_REJECTED" = yes ] && log "the engine has REJECTED the currently deployed keybox — looking for a replacement"
fi

while IFS='|' read -r s_name s_url s_fmt s_status s_pin _junk; do
    [ -n "$s_name" ] || continue
    if ! try_source "$s_name" "$s_url" "$s_fmt" "$s_pin"; then
        continue
    fi
    cand_hash=$(sha "$NEW")
    if bad_payload "$cand_hash"; then
        log "source $s_name: payload ${cand_hash:0:12} was already refused by the engine; skipping"
        continue
    fi
    if [ -n "$CUR_HASH" ] && [ "$cand_hash" = "$CUR_HASH" ] && [ "$CUR_REJECTED" = no ]; then
        if [ "$FORCE" = "1" ]; then
            # Identical content, but the import guard was bypassed: adopt the file
            # so the marker exists and future refreshes maintain it automatically.
            echo "$cand_hash" > "$MARKER"
            chmod 0600 "$MARKER"
            log "force fetch: channel keybox identical to the deployed one; adopted as auto-managed"
            # --force means "make this box take effect NOW": re-deploy so the
            # watcher fires and the daemon pushes again (the engine re-attests
            # the target apps' keys on the ack).
            deploy_atomic "$NEW" && client_recycle
            touch_fetch_ts
            rm -f "$PRE"
            log "done"
            exit 0
        fi
        if [ -f "$MARKER" ]; then
            log "keybox unchanged (hash match, source $s_name); nothing to do"
            touch_fetch_ts
            rm -f "$PRE"
            log "done"
            exit 0
        fi
    fi
    deploy_and_verify "$NEW" "$s_name"
    rc=$?
    if [ "$rc" = 0 ]; then
        WON="$s_name"
        WON_STATUS="$s_status"
        progress "已接受" "$s_name · 引擎应答 applied>0 failed=0"
        break
    fi
    if [ "$rc" = 1 ]; then
        remember_bad "$cand_hash"
        [ -s "$KEYBOX" ] && cp -fL "$KEYBOX" "$BACKUP_DIR/keybox_rejected_$(date +%Y%m%d_%H%M%S).xml" 2>/dev/null
    fi
done < "$TMPD/sources"

if [ -z "$WON" ]; then
    log "ERROR: no source produced a keybox the engine would accept"
    progress "失败" "所有候选源都没通过引擎验收"
    if [ -s "$PRE" ]; then
        log "restoring the keybox that was deployed before this run (engine asked again)"
        deploy_atomic "$PRE" && { engine_verifiable && sh "$VERDICT_SH" watch 10 >/dev/null 2>&1; }
    fi
    rm -f "$PRE"
    exit 7
fi
rm -f "$PRE"

# ---------- refresh the winning source's validity status (best effort) ----------
if [ -n "$WON_STATUS" ]; then
    if fetch "$WON_STATUS" "$STATUS_TXT.new"; then
        mv -f "$STATUS_TXT.new" "$STATUS_TXT"
        chmod 0644 "$STATUS_TXT"
        g=$(grep -o "🟢" "$STATUS_TXT" 2>/dev/null | wc -l | tr -d ' ')
        [ -z "$g" ] && g=0
        echo "$g" > "$STATUS_N"
        chmod 0644 "$STATUS_N"
        log "key-status refreshed: $g green circle(s)"
    else
        rm -f "$STATUS_TXT.new"
        log "key-status fetch failed (keeping previous)"
    fi
else
    # This channel publishes no status file — mark unknown so the WebUI never
    # pairs another channel's status with this keybox.
    echo -1 > "$STATUS_N"
    chmod 0644 "$STATUS_N"
    : > "$STATUS_TXT"
    chmod 0644 "$STATUS_TXT"
    log "source $WON provides no status file; marking unknown"
fi
echo "$WON" > "$SRC_FILE"
chmod 0644 "$SRC_FILE"

# ---------- commit the winner ----------
# The loop above already deployed and had the ENGINE accept this payload, so all
# that is left is to record the provenance the WebUI reads. There is no bounce:
# the rename the deploy performed IS the trigger the daemon watches for.
new_hash=$(sha "$KEYBOX")
if [ -z "$new_hash" ]; then
    log "ERROR: sha256sum unavailable"
    exit 8
fi
echo "$new_hash" > "$MARKER"
chmod 0600 "$MARKER"
log "keybox updated (source $WON, sha256 $new_hash, engine-verified)"

# keep the 5 newest rollback copies (rejected payloads are kept separately)
ls -1t "$BACKUP_DIR"/keybox_*.xml 2>/dev/null | tail -n +6 | while read -r old; do
    rm -f "$old"
done

touch_fetch_ts
client_recycle
log "done (engine accepted the keybox from $WON)"
exit 0
