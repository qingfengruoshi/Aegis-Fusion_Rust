#!/usr/bin/env bash
# harden-pif.sh — assemble-time security hardening for the bundled PlayIntegrityFork
# scripts. Findings U1/U2/U3 from docs/upstream-audit-20260911.md:
#   U1  autopif4.sh hardcodes --no-check-certificate on all 8 wget calls
#   U2  autopif4.sh probes Factory-Image headers over plaintext `nc host 80`
#   U3  migrate.sh evals file-derived config values (root-context injection
#       surface when a hostile custom.pif.json is imported and migrated)
#
# Contract:
#   - Runs on the STAGING COPY only. The SHA256 pin in versions.env still
#     verifies the upstream zip itself; pin semantics are unchanged.
#   - Every patch is asserted: if the upstream text drifts (pin bump), the
#     count mismatch fails the build instead of silently shipping unhardened
#     scripts. Re-review then, and update the patterns here.
#   - Idempotent: re-running on an already-hardened staging tree is a no-op
#     (needed because CI may re-invoke assemble on a cached tree someday).
#   - U1 keeps a compatibility escape hatch: only a genuine TLS/network
#     failure of the probe falls back to the upstream unverified behaviour.
#     v3.2.3 (audit N4): the probe is a full GET (-O /dev/null), NOT --spider
#     — busybox wget cannot do --spider, which made the downgrade the norm
#     instead of the exception on those devices.

harden_pif_scripts() {  # <staging-dir>
  local stage="$1"
  # Native Windows python can't open MSYS virtual paths (/d/...): convert to a
  # Windows mixed path first. No-op on Linux CI (mirrors assemble.sh's zip_dir).
  case "$(uname -s)" in
    MINGW*|MSYS*) command -v cygpath >/dev/null 2>&1 && stage="$(cygpath -m "$stage")" ;;
  esac
  [ -f "$stage/autopif4.sh" ] || { echo "!! harden: $stage/autopif4.sh missing" >&2; return 1; }
  [ -f "$stage/migrate.sh" ] || { echo "!! harden: $stage/migrate.sh missing" >&2; return 1; }

  python3 - "$stage/autopif4.sh" "$stage/migrate.sh" <<'PYEOF'
import sys

def load(path):
    with open(path, encoding="utf-8", newline="") as f:
        # Normalize CRLF -> LF: Android /system/bin/sh cannot execute CRLF
        # scripts, and the pattern math below is LF-based. CI unpacks the PIF
        # zip (LF), but a Windows working-tree copy may carry CRLF.
        return f.read().replace("\r\n", "\n")

def save(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)

def patch(fname, text, name, old, new, expect, guard=None):
    """Replace old->new exactly `expect` times. Skip when already applied
    (new present / guard present). Anything else = upstream drift = fail."""
    if guard and guard in text:
        print(f"      {fname}: {name} already applied")
        return text
    n = text.count(old)
    if n == expect:
        print(f"      {fname}: {name} applied ({n} site(s))")
        return text.replace(old, new)
    if n == 0 and new in text:
        print(f"      {fname}: {name} already applied")
        return text
    print(f"!! harden: {fname}: {name} pattern mismatch (found {n}, expected {expect}) "
          f"— upstream content changed against the pin, review scripts/harden-pif.sh",
          file=sys.stderr)
    sys.exit(2)

# ---------------- autopif4.sh (U1 + U2) ----------------
ap = load(sys.argv[1])

# A: every hardcoded --no-check-certificate becomes the runtime-selected
#    $SSL_FLAG (verified TLS by default, upstream fallback if the probe fails).
ap = patch("autopif4.sh", ap, "U1 flag -> $SSL_FLAG",
           " --no-check-certificate ", " $SSL_FLAG ", 8)

# B: HTTPS-first header probe; plaintext nc:80 demoted to last-resort fallback.
u2_old = (
    'if [ "$FI" -a "$FI_HOST" -a "$FI_PATH" ]; then\n'
    "  nc $FI_HOST 80 <<EOF | tr -d '\\r' > PIXEL_ZIP_HEADERS;\n"
    "HEAD $FI_PATH HTTP/1.1\n"
    "Host: $FI_HOST\n"
    "Connection: close\n"
    "\n"
    "EOF\n"
    "else\n"
    '  warn "Failed to extract Factory Image URL from JSON";\n'
    "fi;\n"
    "if [ ! -s PIXEL_ZIP_HEADERS ] || ! grep -q 'Last-Modified' PIXEL_ZIP_HEADERS; then\n"
    '  wget -q -T 10 -S --spider -o PIXEL_ZIP_HEADERS $SSL_FLAG "$FI" 2>&1;\n'
    "fi;\n"
)
u2_new = (
    'if [ "$FI" -a "$FI_HOST" -a "$FI_PATH" ]; then\n'
    '  wget -q -T 10 -S --spider -o PIXEL_ZIP_HEADERS $SSL_FLAG "$FI" 2>&1;\n'
    "  if [ ! -s PIXEL_ZIP_HEADERS ] || ! grep -q 'Last-Modified' PIXEL_ZIP_HEADERS; then\n"
    '    warn "HTTPS header probe failed, trying plaintext fallback";\n'
    "    nc $FI_HOST 80 <<EOF | tr -d '\\r' > PIXEL_ZIP_HEADERS;\n"
    "HEAD $FI_PATH HTTP/1.1\n"
    "Host: $FI_HOST\n"
    "Connection: close\n"
    "\n"
    "EOF\n"
    "  fi;\n"
    "else\n"
    '  warn "Failed to extract Factory Image URL from JSON";\n'
    "fi;\n"
)
ap = patch("autopif4.sh", ap, "U2 HTTPS-first header probe",
           u2_old, u2_new, 1, guard='HTTPS header probe failed')

# C: TLS capability probe — verified TLS unless this wget cannot do it.
#    v3.2.3 (audit N4): the probe is a FULL GET of a small page, not --spider
#    (busybox wget lacks --spider, so the old probe failed there on every run
#    and the downgrade became the default). -O /dev/null works on toybox and
#    busybox alike, so only a real TLS/network failure downgrades — and the
#    downgrade is loudly logged when it happens.
probe_anchor = 'fi;\n\nif date -D \'%s\' -d "$(date \'+%s\')"'
probe_block = (
    'fi;\n'
    '\n'
    'SSL_FLAG="";\n'
    'if wget -q -T 10 -O /dev/null "https://developer.android.com/about/versions" 2>/dev/null; then\n'
    '  echo "TLS verification: enabled (wget verified the CA chain)";\n'
    'else\n'
    '  SSL_FLAG="--no-check-certificate";\n'
    '  echo "TLS verification: probe FAILED — downloads will SKIP certificate checks";\n'
    '  echo "  (downgrade is an exception, not the default; if this appears on every run your network is intercepting TLS)";\n'
    'fi;\n'
    '\n'
    'if date -D \'%s\' -d "$(date \'+%s\')"'
)
ap = patch("autopif4.sh", ap, "U1 TLS capability probe",
           probe_anchor, probe_block, 1, guard='SSL_FLAG=""')

# ---------------- autopif4.sh (S1 seed-compat, 2026-09-17) ----------------
# Google dropped the '"canary": true' flag from the flashstation builds JSON
# (RC cycle): the API still returns valid builds (product/buildId/
# releaseCandidateName/factoryImageDownloadUrl/target) but autopif4's anchor
# grep matches nothing -> "Failed to extract build info from JSON" -> no seed
# (seen live: 64dd168 build, 2026-09-17). Upstream main only retries other
# devices and keeps the dead anchor, so the fix lives here until upstream
# ships it. Three fallbacks, each independently guarded:
#   S1a  newest object instead of the canary-flagged one (tac reversal puts
#        the newest build's releaseCandidateName/buildId first)
#   S1b  newest object's factory URL (the -A13 window misses it in fallback
#        mode; needed for the Last-Modified release-date estimation)
#   S1c  canary-id derived from the RC name (CP41.260828.004.A8 -> 2026-08)
#        so the bulletin month lookup / -05 day fallback keep a plausible
#        SECURITY_PATCH date (the new JSON has no "id" field at all)
ap = patch("autopif4.sh", ap, "S1a canary anchor fallback",
           '''tac PIXEL_STATION_JSON | grep -m1 -A13 '"canary": true' > PIXEL_CANARY_JSON;
ID="$(grep 'releaseCandidateName' PIXEL_CANARY_JSON | cut -d\\" -f4)";
INCREMENTAL="$(grep 'buildId' PIXEL_CANARY_JSON | cut -d\\" -f4)";
[ -z "$ID" -o -z "$INCREMENTAL" ] && die "Failed to extract build info from JSON";''',
           '''tac PIXEL_STATION_JSON | grep -m1 -A13 '"canary": true' > PIXEL_CANARY_JSON;
ID="$(grep 'releaseCandidateName' PIXEL_CANARY_JSON | cut -d\\" -f4)";
INCREMENTAL="$(grep 'buildId' PIXEL_CANARY_JSON | cut -d\\" -f4)";
if [ -z "$ID" -o -z "$INCREMENTAL" ]; then
  # [fusion seed-compat: anchor]
  ID="$(tac PIXEL_STATION_JSON | grep -m1 'releaseCandidateName' | cut -d\\" -f4)";
  INCREMENTAL="$(tac PIXEL_STATION_JSON | grep -m1 'buildId' | cut -d\\" -f4)";
fi;
[ -z "$ID" -o -z "$INCREMENTAL" ] && die "Failed to extract build info from JSON";''',
           1, guard='[fusion seed-compat: anchor]')

ap = patch("autopif4.sh", ap, "S1b factory-url fallback",
           '''FI="$(grep 'factoryImageDownloadUrl' PIXEL_CANARY_JSON | cut -d\\" -f4)";''',
           '''FI="$(grep 'factoryImageDownloadUrl' PIXEL_CANARY_JSON | cut -d\\" -f4)";
# [fusion seed-compat: factory-url]
[ -z "$FI" ] && FI="$(tac PIXEL_STATION_JSON | grep -m1 'factoryImageDownloadUrl' | cut -d\\" -f4)";''',
           1, guard='[fusion seed-compat: factory-url]')

ap = patch("autopif4.sh", ap, "S1c canary-id fallback",
           '''CANARY_ID="$(grep '"id"' PIXEL_CANARY_JSON | sed -e 's;.*canary-\\(.*\\)".*;\\1;' -e 's;^\\(.\\{4\\}\\);\\1-;')";
[ -z "$CANARY_ID" ] && die "Failed to extract build info from JSON";''',
           '''CANARY_ID="$(grep '"id"' PIXEL_CANARY_JSON | sed -e 's;.*canary-\\(.*\\)".*;\\1;' -e 's;^\\(.\\{4\\}\\);\\1-;')";
if [ -z "$CANARY_ID" ]; then
  # [fusion seed-compat: canary-id]
  CANARY_ID="$(echo "$ID" | sed -n 's;^[A-Za-z0-9]*\\.\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)[0-9]\\{2\\}\\..*;20\\1-\\2;p')";
fi;
[ -z "$CANARY_ID" ] && die "Failed to extract build info from JSON";''',
           1, guard='[fusion seed-compat: canary-id]')

# ---------------- autopif4.sh (R7-2, 2026-09-19) ----------------
# The advanced-settings passthrough interpolates a user-supplied value straight
# into a sed REPLACEMENT. Backslashes, `&` and the `;` delimiter mangle or
# terminate that script; props allow arbitrary text, so escape for the sed
# dialect first. Benign values (fingerprint fields, versions) are unaffected.
# Raw strings on purpose: a regular string once turned \1 into a control char.
ap = patch("autopif4.sh", ap, "R7-2 escape the advanced value for sed",
           r"""      [ -n "$TMPVAL" ] && sed -i "s;\($SETTING=\).;\1$TMPVAL;" custom.pif.prop;""",
           r"""      if [ -n "$TMPVAL" ]; then
        # R7-2: escape for the sed replacement (backslash, & and ; delimiter)
        TMPVAL_ESC=$(printf '%s' "$TMPVAL" | tr -d '\n\r' | sed -e 's/[\\&;]/\\&/g');
        sed -i "s;\($SETTING=\).;\1$TMPVAL_ESC;" custom.pif.prop;
      fi;""",
           1, guard='R7-2: escape for the sed replacement')

for name, text, checks in (
    ("autopif4.sh", ap, (
        ("literal --no-check-certificate count", ap.count("--no-check-certificate"), 1),
        ("$SSL_FLAG use count", ap.count("$SSL_FLAG"), 8),
        ("plaintext nc count", ap.count("nc $FI_HOST 80"), 1),
        ("probe default present", int('SSL_FLAG=""' in ap), 1),
        ("seed-compat patches applied", ap.count("fusion seed-compat"), 3),
        ("R7-2 sed escape present", int('R7-2: escape for the sed replacement' in ap), 1),
    )),
):
    for label, got, want in checks:
        if got != want:
            print(f"!! harden: {name}: {label} = {got}, expected {want}", file=sys.stderr)
            sys.exit(2)
save(sys.argv[1], ap)

# ---------------- migrate.sh (U3) ----------------
mg = load(sys.argv[2])

# grep_get_json: the eval re-parsed file-derived JSON values as shell syntax.
# set -- "..." feeds the same bytes as pure data (quote handling that the old
# eval accidentally performed is deliberately dropped — see keep-value note in
# the audit report; benign fingerprint/model values are unaffected).
mg = patch("migrate.sh", mg, "U3 grep_get_json de-eval",
           'eval set -- "$(cat "$2"',
           'set -- "$(cat "$2"', 1)

# Field capture loop: same indirection-safe dynamic assignment.
mg = patch("migrate.sh", mg, "U3 field capture de-eval",
           'eval $FIELD=\\"$(grep_get_config $FIELD)\\";',
           'VALUE="$(grep_get_config $FIELD)"; eval "$FIELD=\\$VALUE";', 1)

# ---------------- migrate.sh (R7-2, 2026-09-19) ----------------
# In JSON mode a field VALUE is written inside a JSON string: an unescaped `"`
# or backslash breaks the document (a crafted value could even append keys).
# Values come from the user's own old config - data-safety, not escalation -
# but it is the M6 class of bug and cheap to close here. Prop mode is
# unchanged (raw text is legal in a prop file).
mg = patch("migrate.sh", mg, "R7-2 escape JSON field values (build fields)",
           r"""for FIELD in $ALLFIELDS; do
  eval echo "$EVALPRE$FIELD\$MID\$$FIELD\$POST";
done;""",
           r"""for FIELD in $ALLFIELDS; do
  eval FIELDVAL=\$$FIELD;
  if [ "$FORMAT" = "json" ]; then
    FIELDVAL=$(printf '%s' "$FIELDVAL" | tr -d '\n\r' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g');
  fi;
  eval echo "$EVALPRE$FIELD\$MID\$FIELDVAL\$POST";
done;""",
           1, guard='R7-2 escape JSON field values (build fields)')

mg = patch("migrate.sh", mg, "R7-2 escape JSON field values (advanced settings)",
           r"""  for SETTING in $ADVSETTINGS; do
    eval echo "$EVALPRE$SETTING\$MID\$$SETTING\$POST";
  done;""",
           r"""  for SETTING in $ADVSETTINGS; do
    eval SETTINGVAL=\$$SETTING;
    if [ "$FORMAT" = "json" ]; then
      SETTINGVAL=$(printf '%s' "$SETTINGVAL" | tr -d '\n\r' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g');
    fi;
    eval echo "$EVALPRE$SETTING\$MID\$SETTINGVAL\$POST";
  done;""",
           1, guard='R7-2 escape JSON field values (advanced settings)')

# keep_advanced: guard/assign split, value never re-parsed.
mg = patch("migrate.sh", mg, "U3 keep_advanced de-eval",
           'eval grep_check_config $SETTING \\"$1\\" \\&\\& $SETTING=\\"$(grep_get_config $SETTING "$1")\\";',
           'if grep_check_config $SETTING "$1"; then VALUE="$(grep_get_config $SETTING "$1")"; eval "$SETTING=\\$VALUE"; fi;', 1)

for label, got, want in (
    # 3 untouched-safe evals (fixed-list indirect echo/assignment) + 2 new
    # indirection-safe assignments introduced by the U3 rewrites + 2 R7-2
    # fixed-list `eval echo` line builders (the value itself is escaped data).
    ("remaining eval count", mg.count("eval "), 7),
    ("eval set -- removed", int('eval set --' in mg), 0),
    ("vulnerable eval $FIELD=\" removed", int('eval $FIELD=\\"' in mg), 0),
    ("eval grep_check_config removed", int('eval grep_check_config' in mg), 0),
    ("safe field assignment present", int('eval "$FIELD=\\$VALUE"' in mg), 1),
    ("R7-2 JSON escape (build fields) present", int('eval FIELDVAL=\\$$FIELD' in mg), 1),
    ("R7-2 JSON escape (advanced) present", int('eval SETTINGVAL=\\$$SETTING' in mg), 1),
    ("safe setting assignment present", int('eval "$SETTING=\\$VALUE"' in mg), 1),
):
    if got != want:
        print(f"!! harden: migrate.sh: {label} = {got}, expected {want}", file=sys.stderr)
        sys.exit(2)
save(sys.argv[2], mg)

print("      harden: all patches verified")
PYEOF
  local py_rc=$?
  [ "$py_rc" -eq 0 ] || { echo "!! harden: patch application failed (rc=$py_rc)" >&2; return 1; }

  # The hardened scripts must still parse under /system/bin/sh (dash in CI).
  sh -n "$stage/autopif4.sh" || { echo "!! harden: autopif4.sh failed sh -n" >&2; return 1; }
  sh -n "$stage/migrate.sh" || { echo "!! harden: migrate.sh failed sh -n" >&2; return 1; }
  return 0
}
