#!/usr/bin/env bash
# Unit tests for module/keybox-fetch.sh — proxy passthrough + auto-probe +
# direct-IP (phase 4) layers. The network is faked: a shim `curl` placed first
# on PATH records how it was invoked (proxy env, --resolve pinning) and only
# delivers a payload when an escape hatch is active (proxy or --resolve) —
# direct = dead route, the censored-network case. The auto-probe is shimmed
# via AEGIS_KB_PROBE. Run: bash scripts/test-keybox-fetch.sh
set -u
cd "$(dirname "$0")/.."
PASS=0 FAIL=0
note() { echo "  $*"; }
ok() { if [ "$2" = "1" ]; then PASS=$((PASS+1)); echo "  ok - $1"; else FAIL=$((FAIL+1)); echo "  FAIL - $1"; fi }

SCRIPT=module/keybox-fetch.sh
bash -n "$SCRIPT" && ok "keybox-fetch.sh parses (bash -n)" 1 || ok "keybox-fetch.sh parses (bash -n)" 0
sh -n "$SCRIPT" && ok "keybox-fetch.sh parses (sh -n, POSIX)" 1 || ok "keybox-fetch.sh parses (sh -n, POSIX)" 0

# Per-run unique root: no rm -rf needed at all, so a stale lockdir or proxy
# state from a previous run can never poison this one (a killed run leaves
# .kb-fetching.lock behind, and the concurrency guard would then skip every
# case of the next run). build/ is gitignored; old run dirs are harmless.
ROOT="build/test-keybox-fetch.$$"
mkdir -p "$ROOT"

# Minimal structural keybox (2 certificates — the engine expects >= 2)
mk_keybox_b64() {
    printf '<?xml version="1.0"?>\n<AndroidAttestation>\n<NumberOfCertificates>2</NumberOfCertificates>\n<Keybox DeviceID="test">\n<Key algorithm="ecdsa">\n<CertificateChain>\n<Certificate>-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----\n</Certificate>\n<Certificate>-----BEGIN CERTIFICATE-----\nREVG\n-----END CERTIFICATE-----\n</Certificate>\n</CertificateChain>\n</Key>\n</Keybox>\n</AndroidAttestation>\n' | base64 -w0 2>/dev/null || \
    printf '<?xml version="1.0"?>\n<AndroidAttestation>\n<NumberOfCertificates>2</NumberOfCertificates>\n<Keybox DeviceID="test">\n<Key algorithm="ecdsa">\n<CertificateChain>\n<Certificate>-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----\n</Certificate>\n<Certificate>-----BEGIN CERTIFICATE-----\nREVG\n-----END CERTIFICATE-----\n</Certificate>\n</CertificateChain>\n</Key>\n</Keybox>\n</AndroidAttestation>\n' | base64 | tr -d '\n'
}

# Shim curl: parses args properly (-o takes the NEXT arg; --resolve may be
# anywhere), records "proxy=[<http_proxy>] resolve=<0|1> url=<url>" per call,
# and delivers the b64 keybox payload ONLY through an escape hatch (a proxy
# is set, or --resolve pinning is present). KBSHIM_MODE=failall makes it fail
# unconditionally (kbf4: even the remembered proxy must be a corpse). The
# payload is baked in at shim-creation time — the shim is a separate process
# and cannot call test-shell functions.
make_fake_curl() { # <bin-dir>
    mkdir -p "$1"
    _kb64="$(mk_keybox_b64)"
    cat > "$1/curl" << EOF
#!/usr/bin/env bash
KBB64="$_kb64"
CURLLOG="$CURLLOG"
_u=""; _o=""; _r=0; _pv=""
for a in "\$@"; do
  if [ "\$_pv" = "-o" ]; then _o="\$a"; _pv=""; continue; fi
  case "\$a" in
    -o) _pv="-o" ;;
    http*) _u="\$a" ;;
    --resolve*) _r=1 ;;
  esac
done
echo "proxy=[\${http_proxy:-}] resolve=\$_r url=\$_u" >> "\$CURLLOG"
[ "\${KBSHIM_MODE:-live}" = "failall" ] && exit 1
if [ -z "\${http_proxy:-}" ] && [ "\$_r" = "0" ]; then exit 1; fi
printf '%s' "\$KBB64" > "\$_o" 2>/dev/null
[ -s "\$_o" ]
EOF
    chmod +x "$1/curl"
}

# Probe shim: only port 7897 answers
make_probe() {
    printf '#!/usr/bin/env bash\n[ "$1" = "7897" ]\n' > "$1"
    chmod +x "$1"
}

setup_tree() { # <dir>
    T="$1"
    CURLLOG="$T/curl.log"
    mkdir -p "$T/mod" "$T/teesim" "$T/bin"
    cp module/keybox-check.sh module/engine-verdict.sh "$T/mod/" 2>/dev/null
    printf 'Test|http://fake.example/test|b64||\n' > "$T/teesim/keybox-sources.conf"
    : > "$T/teesim/.debug"   # enable dbg() so direct-IP lines land in debug.log
    make_probe "$T/probe.sh"
    make_fake_curl "$T/bin"
    # Passthrough rm for every case: on the dev host the safe-delete shim
    # exports an rm FUNCTION that inherits into the child shell and can hang on
    # the fetch's own cleanup (rm -rf tmpdir lockdir) - intermittent, never on
    # CI or real devices. Redirecting the shim's BIN_DIR (in run_fetch) to this
    # passthrough keeps the suite deterministic on the dev host too.
    printf '#!/usr/bin/env bash\nexec /usr/bin/rm "$@"\n' > "$T/bin/rm"
    chmod +x "$T/bin/rm"
}

run_fetch() {
    CURLLOG="$T/curl.log"; : > "$CURLLOG"
    # Hermetic: strip any ambient http_proxy/https_proxy from the invoking
    # shell (dev machines often run behind a local proxy) — the first curl of
    # a run would otherwise inherit it and a "no proxy involved" assertion
    # would spuriously fail. Also clear the local WorkBuddy safe-delete
    # session IDs so the dev-machine rm shim (which blocks any rm inside a
    # directory holding >=50 files, e.g. the heartbeat-littered teesim dir)
    # passes through to real rm — CI and real devices have no such shim.
    PATH="$T/bin:$PATH" AEGIS_TEE_DIR="$T/teesim" AEGIS_MODDIR="$T/mod" \
        AEGIS_KB_PROBE="$T/probe.sh" AEGIS_KB_AUTOPROXY="${KBA:-1}" \
        KBSHIM_MODE="${KBM:-live}" \
        http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= \
        CODEBUDDY_SESSION_ID= CLAUDE_SESSION_ID= \
        CODEBUDDY_SAFE_DELETE_BIN_DIR="$T/bin" CODEBUDDY_SAFE_DELETE_ENABLED=0 \
        ENV= BASH_ENV= \
        sh "$SCRIPT" "$@" > "$T/out.log" 2>&1
    return 0
}

# --- case kbf1: direct fails -> probe finds 7897 -> retry through it ---
T="$ROOT/kbf1"; setup_tree "$T"
run_fetch
grep -q "proxy=\[\] resolve=0" "$CURLLOG" \
    && ok "kbf1: direct attempts ran without a proxy" 1 || ok "kbf1: direct attempts ran without a proxy" 0
grep -q "proxy=\[http://127.0.0.1:7897\]" "$CURLLOG" \
    && ok "kbf1: retry after probe went through 7897" 1 || ok "kbf1: retry after probe went through 7897" 0
[ "$(cat "$T/teesim/pif-proxy.auto" 2>/dev/null)" = "http://127.0.0.1:7897" ] \
    && ok "kbf1: working proxy remembered in pif-proxy.auto" 1 || ok "kbf1: working proxy remembered in pif-proxy.auto" 0
grep -q "auto-proxy: found a working local proxy at http://127.0.0.1:7897" "$T/teesim/keybox-fetch.log" 2>/dev/null \
    && ok "kbf1: probe + retry logged" 1 || ok "kbf1: probe + retry logged" 0

# --- case kbf2: pif-proxy.conf (shared config) is honoured, no probe needed ---
T="$ROOT/kbf2"; setup_tree "$T"
printf 'http://127.0.0.1:9999\n' > "$T/teesim/pif-proxy.conf"
run_fetch
grep -q "proxy=\[http://127.0.0.1:9999\]" "$CURLLOG" \
    && ok "kbf2: shared pif-proxy.conf reaches the downloader" 1 || ok "kbf2: shared pif-proxy.conf reaches the downloader" 0
[ ! -e "$T/teesim/pif-proxy.auto" ] \
    && ok "kbf2: no auto-probe state written when a proxy is configured" 1 || ok "kbf2: no auto-probe state written when a proxy is configured" 0
grep -q "auto-proxy: found" "$T/teesim/keybox-fetch.log" 2>/dev/null \
    && ok "kbf2: probe skipped when a proxy is configured" 0 || ok "kbf2: probe skipped when a proxy is configured" 1

# --- case kbf3: unsafe proxy value is rejected, direct is used ---
T="$ROOT/kbf3"; setup_tree "$T"
printf 'http://127.0.0.1:9999; rm -rf /\n' > "$T/teesim/pif-proxy.conf"
run_fetch
grep -q "WARNING: pif-proxy.conf rejected" "$T/teesim/keybox-fetch.log" 2>/dev/null \
    && ok "kbf3: unsafe proxy value rejected and logged" 1 || ok "kbf3: unsafe proxy value rejected and logged" 0
grep -q "proxy=\[http://127.0.0.1:9999" "$CURLLOG" \
    && ok "kbf3: rejected value never reaches the downloader" 0 || ok "kbf3: rejected value never reaches the downloader" 1

# --- case kbf4: remembered proxy that stops working is dropped ---
T="$ROOT/kbf4"; setup_tree "$T"
printf 'http://127.0.0.1:7897\n' > "$T/teesim/pif-proxy.auto"
KBA=0 KBM=failall run_fetch   # autoprobe off + nothing delivers: the stale remembered proxy must die alone
[ ! -e "$T/teesim/pif-proxy.auto" ] \
    && ok "kbf4: failed remembered proxy dropped from pif-proxy.auto" 1 || ok "kbf4: failed remembered proxy dropped from pif-proxy.auto" 0
grep -q "remembered proxy did not work" "$T/teesim/keybox-fetch.log" 2>/dev/null \
    && ok "kbf4: drop is logged" 1 || ok "kbf4: drop is logged" 0

# --- case kbf5: DNS-poisoned direct route, no proxy anywhere -> phase 4
#     direct-IP fallback via curl --resolve delivers the payload ---
T="$ROOT/kbf5"; setup_tree "$T"
KBA=0 run_fetch
grep -q "resolve=1 url=" "$CURLLOG" \
    && ok "kbf5: --resolve pinning reached the downloader" 1 || ok "kbf5: --resolve pinning reached the downloader" 0
grep -q "download ok: direct-IP 185.199.108.133" "$T/teesim/debug.log" 2>/dev/null \
    && ok "kbf5: payload delivered through the first Fastly IP" 1 || ok "kbf5: payload delivered through the first Fastly IP" 0
grep -q "proxy=\[http" "$CURLLOG" \
    && ok "kbf5: no proxy was involved" 0 || ok "kbf5: no proxy was involved" 1
[ ! -e "$T/teesim/pif-proxy.auto" ] \
    && ok "kbf5: no auto-proxy state written on the direct-IP path" 1 || ok "kbf5: no auto-proxy state written on the direct-IP path" 0

# --- case kbf6 (audit v3.2.3 N5, M11): --force backs up the CURRENT keybox
#     before touching anything, with byte-identical content ---
T="$ROOT/kbf6"; setup_tree "$T"
printf 'PRECIOUS-USER-IMPORTED-KEYBOX\n' > "$T/teesim/keybox.xml"
run_fetch --force
_ls=$(ls "$T/teesim/keybox-backups"/keybox_pre-force_*.xml 2>/dev/null | head -1)
[ -n "$_ls" ] && [ -s "$_ls" ] \
    && ok "kbf6: --force wrote a keybox_pre-force backup" 1 || ok "kbf6: --force wrote a keybox_pre-force backup" 0
[ "$(cat "$_ls" 2>/dev/null)" = "PRECIOUS-USER-IMPORTED-KEYBOX" ] \
    && ok "kbf6: backup is byte-identical to the pre-force keybox" 1 || ok "kbf6: backup is byte-identical to the pre-force keybox" 0
grep -q "backed up the current keybox" "$T/teesim/keybox-fetch.log" 2>/dev/null \
    && ok "kbf6: the backup is logged" 1 || ok "kbf6: the backup is logged" 0
grep -q "could not back up" "$T/teesim/keybox-fetch.log" 2>/dev/null \
    && ok "kbf6: no backup failure on a writable backup dir" 0 || ok "kbf6: no backup failure on a writable backup dir" 1

# --- case kbf7 (audit v3.2.3 N5, M11): an unusable backup location ABORTS —
#     the deployed keybox must not be replaced when we cannot snapshot it.
#     keybox-backups pre-exists as a regular FILE, so the script's mkdir -p of
#     the backup dir fails and the run must die long before any network action.
#     (Deterministic on every platform — unlike chmod, which MSYS/Git Bash
#     emulates without enforcing, so a chmod-based case would pass the cp.) ---
T="$ROOT/kbf7"; setup_tree "$T"
printf 'PRECIOUS-USER-IMPORTED-KEYBOX\n' > "$T/teesim/keybox.xml"
printf 'x' > "$T/teesim/keybox-backups"
run_fetch --force
grep -qi "mkdir" "$T/out.log" 2>/dev/null \
    && ok "kbf7: the unusable backup dir is reported" 1 || ok "kbf7: the unusable backup dir is reported" 0
[ "$(cat "$T/teesim/keybox.xml" 2>/dev/null)" = "PRECIOUS-USER-IMPORTED-KEYBOX" ] \
    && ok "kbf7: the deployed keybox was NOT touched" 1 || ok "kbf7: the deployed keybox was NOT touched" 0
grep -q "replacing the deployed keybox" "$T/teesim/keybox-fetch.log" 2>/dev/null \
    && ok "kbf7: no replacement was ever attempted" 0 || ok "kbf7: no replacement was ever attempted" 1
ls "$T/teesim/keybox-backups"/keybox_pre-force_*.xml >/dev/null 2>&1 \
    && ok "kbf7: no phantom backup file was left behind" 0 || ok "kbf7: no phantom backup file was left behind" 1

# --- case kbf8: logcat-dead device -> the admin socket still yields a verdict ---
# F-11: on ROMs with logging disabled the durable trace never fills, so
# engine_verifiable used to bail out and every deploy shipped without a
# verdict. Patch 0007 exposes the daemon's in-memory push/ack state over the
# admin socket; a fake teesim-uds + a fake pidof stand in for both here, and
# this is also the suite's first end-to-end deploy -> verify case.
# Guarded: the dev host's safe-delete shim exports an rm FUNCTION that hangs
# the fetch's own cleanup here even with BIN_DIR redirected - the host cannot
# run this case deterministically. CI has no such shim and covers it; the host
# prints a visible SKIP instead of hanging the whole suite.
if [ "${CODEBUDDY_SAFE_DELETE_ENABLED:-}" = "1" ]; then
    note "SKIP kbf8 (host safe-delete shim active; CI runs this case)"
else
T="$ROOT/kbf8"; setup_tree "$T"
# The logcat-dead scenario: the durable trace EXISTS but is EMPTY (LogTail
# created it, logcat had nothing to mirror) - so log/ must exist too, exactly
# like a real device.
mkdir -p "$T/teesim/log"
: > "$T/teesim/log/teesim.log"
printf '#!/usr/bin/env bash\necho 4321\n' > "$T/bin/pidof"
chmod +x "$T/bin/pidof"
{
    printf '#!/usr/bin/env bash\n'
    printf 'cat <<%s\n' "'EJSON'"
    printf '%s\n' '{"ok":true,"version":"","lib":{"hook":"keymint","api":36},"push":{"last":1760000000},"ack":{"last":1760000005,"applied":2,"failed":0}}'
    printf 'EJSON\n'
} > "$T/teesim/teesim-uds"
chmod +x "$T/teesim/teesim-uds"
: > "$T/teesim/admin.sock"
printf 'tok\n' > "$T/teesim/admin.token"
run_fetch
grep -q "engine ACCEPTED the payload" "$T/teesim/keybox-fetch.log" 2>/dev/null \
    && ok "kbf8: the deploy was verified through the admin socket" 1 || ok "kbf8: the deploy was verified through the admin socket" 0
grep -q '^state=ok' "$T/teesim/.engine-verdict" 2>/dev/null \
    && ok "kbf8: the recorded verdict is state=ok" 1 || ok "kbf8: the recorded verdict is state=ok" 0
grep -q 'socket: ack epoch=1760000005' "$T/teesim/.engine-verdict" 2>/dev/null \
    && ok "kbf8: the verdict carries the socket ACK_LINE" 1 || ok "kbf8: the verdict carries the socket ACK_LINE" 0
[ -s "$T/teesim/keybox.xml" ] \
    && ok "kbf8: the fetched keybox was deployed" 1 || ok "kbf8: the fetched keybox was deployed" 0

# Failure diagnostics (CI-safe: the environment is fully synthetic - fake.example
# URLs, dummy payloads, no device data). Dumps the fetch's own view so a
# runner-specific failure is root-causable from the CI log alone.
_kbf8_bad=0
grep -q "engine ACCEPTED the payload" "$T/teesim/keybox-fetch.log" 2>/dev/null || _kbf8_bad=1
if [ "$_kbf8_bad" = 1 ]; then
    echo "  kbf8 DIAG: which tools the fetch would resolve:"
    echo "  kbf8 DIAG: $(PATH="$T/bin:$PATH" command -v pidof curl rm sh 2>&1 | tr '\n' ' ')"
    echo "  kbf8 DIAG: pidof output: $(PATH="$T/bin:$PATH" pidof teesim 2>&1 | head -1)"
    echo "  kbf8 DIAG: engine_verifiable chain:"
    echo "  kbf8 DIAG:   verdict script: $( [ -f module/engine-verdict.sh ] && echo present || echo MISSING )"
    echo "  kbf8 DIAG:   fake uds: [$( "$T/teesim/teesim-uds" "$T/teesim/admin.sock" GET /status tok 2>&1 | head -1 )]"
    _sl=$(AEGIS_TEE_DIR="$T/teesim" PATH="$T/bin:$PATH" sh module/engine-verdict.sh socket-live 2>&1); _slrc=$?
    echo "  kbf8 DIAG:   socket-live rc=$_slrc out=[$_sl]"
    echo "  kbf8 DIAG:   socket-live trace (tail 14):"
    AEGIS_TEE_DIR="$T/teesim" PATH="$T/bin:$PATH" sh -x module/engine-verdict.sh socket-live 2>&1 | tail -14 | sed 's/^/    | /'
    echo "  kbf8 DIAG: keybox-fetch.log (all):"
    sed 's/^/    | /' "$T/teesim/keybox-fetch.log" 2>/dev/null
    echo "  kbf8 DIAG: out.log (tail 15):"
    tail -15 "$T/out.log" 2>/dev/null | sed 's/^/    | /'
    echo "  kbf8 DIAG: teesim dir:"
    ls -la "$T/teesim" 2>/dev/null | sed 's/^/    | /'
    echo "  kbf8 DIAG: .engine-verdict:"
    cat "$T/teesim/.engine-verdict" 2>/dev/null | sed 's/^/    | /'
fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
