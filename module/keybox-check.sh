#!/system/bin/sh
# keybox-check.sh — structural validator for a KeyMint keybox.xml, matching
# exactly what the TEESimulator TA requires when it builds a profile.
#
# WHY THIS EXISTS. The module used to validate a keybox with two greps:
#     grep -q "<Keybox" && grep -q "PrivateKey"
# A keybox can satisfy both and still be completely unusable by the engine:
#   * a <Key> element with no algorithm attribute (or only attributes the TA
#     does not look for)
#   * a chain carrying only ONE <Certificate>        <-- the TA requires >= 2
#   * a truncated / still-obfuscated / HTML-error body (base64 decode fails)
#   * an <PrivateKey> whose body is empty
#   * a body with INVALID base64 ("an interior '='") — see Rule 5
#
# When that happens the engine emits exactly two lines and nothing else:
#     E TEESimulator: keymint: profile default failed to build (bad keybox?)
#     I TEESimulator: control: ack epoch=... ok=true applied=0 failed=1
# It then DROPS every profile, so g_profiles stays empty, so every request is
# logged `target=0` and forwarded to the real HAL, so the device sits at
# one-green (BASIC only) with every external indicator looking healthy — the
# exact failure that cost this project two days. This script turns that silent
# downstream symptom into a named, up-front error.
#
# THE RULES below mirror rust/teesim-km/src/attest.rs (CertSignInfo::new ->
# parse_algo -> decode_pem), in the same order the TA evaluates them, and the
# reason strings are worded so they line up with the Rust ones.
#
# Usage: keybox-check.sh <file> [--quiet]
# Exit : 0 usable | 1 unusable | 2 missing / unreadable / not a regular file

F="$1"
QUIET=""
[ "$2" = "--quiet" ] && QUIET=1

say() { [ -n "$QUIET" ] || echo "$*"; }

[ -n "$F" ] || { [ -n "$QUIET" ] || echo "usage: keybox-check.sh <file> [--quiet]"; exit 2; }
[ -e "$F" ] || { say "FAIL: not found: $F"; exit 2; }
# A symlink is legal, but it is also how a keybox silently stops matching the
# file the user thinks is deployed (TrickyStore's copy moving out from under us).
# Report it so the operator can decide; it is not by itself a failure.
[ -L "$F" ] && say "note: $F is a symlink -> $(readlink "$F" 2>/dev/null)"
[ -f "$F" ] || { say "FAIL: not a regular file: $F"; exit 2; }
[ -s "$F" ] || { say "FAIL: empty file: $F"; exit 2; }

# --- Rule 1: the document must parse as the XML the TA expects -----------------
# We cannot run a real XML parser in a boot shell, so this is the practical
# proxy: a Keybox root element plus a closing tag, with a sane byte shape.
grep -q "<Keybox" "$F" 2>/dev/null || { say "FAIL: no <Keybox> root element (not a keybox document)"; exit 1; }
grep -q "</Keybox>" "$F" 2>/dev/null || { say "FAIL: <Keybox> is never closed — truncated download?"; exit 1; }
# An HTML error page saved as .xml is a classic failed-download outcome.
head -c 200 "$F" | grep -qiE "<!doctype html|<html" && { say "FAIL: file is an HTML page, not a keybox (failed download saved as XML)"; exit 1; }

# --- Rule 2/3: per <Key> block, algorithm + chain length ----------------------
# `Certificate` (not `CertificateChain`) is what the TA counts, and it counts
# descendants, so the count is per Key block until </Key>.
KEYS=$(awk '
  /<Key[ \t>]/ {
    if (k) printf "%s %d\n", a, c;
    k = 1; c = 0; a = "-"
    if (match($0, /algorithm="[^"]*"/)) a = substr($0, RSTART + 11, RLENGTH - 12)
    next
  }
  k && /<\/Key>/ { printf "%s %d\n", a, c; k = 0; next }
  k && /<Certificate[ >]/ { c++ }
  END { if (k) printf "%s %d\n", a, c }
' "$F" 2>/dev/null)

[ -n "$KEYS" ] || { say "FAIL: no <Key> element found ('keybox: no <Key algorithm=\"rsa\"> or <Key algorithm=\"ecdsa\">')"; exit 1; }

USABLE=""
BROKEN=""

# Walk the blocks: a block is usable only if its algorithm is one the TA looks
# for (exactly "rsa" or "ecdsa") AND it carries at least two certificates.
while read -r algo certs; do
    [ -n "$algo" ] || continue
    case "$algo" in
        rsa|ecdsa)
            if [ "${certs:-0}" -ge 2 ] 2>/dev/null; then
                say "ok  : <Key algorithm=\"$algo\"> carries $certs certificate(s)"
                USABLE=1
            else
                say "FAIL: <Key algorithm=\"$algo\"> chain has $certs certificate(s); the TA needs at least 2 ('$algo: expected at least 2 certificates')"
                BROKEN=1
            fi
            ;;
        *)
            say "warn: <Key algorithm=\"$algo\"> is not one the TA reads (only rsa / ecdsa are)"
            ;;
    esac
done <<EOF
$KEYS
EOF

if [ -z "$USABLE" ]; then
    [ -n "$BROKEN" ] || say "FAIL: no <Key algorithm=\"rsa\"> or <Key algorithm=\"ecdsa\"> with a usable chain"
    say "      -> the engine will log 'keymint: profile <id> failed to build (bad keybox?)'"
    say "         and drop every profile: PI stays at BASIC no matter what else is configured."
    exit 1
fi

# --- Rule 4: the bodies must be non-empty ------------------------------------
# decode_pem() extracts a body by dropping empty lines and every line that starts
# with '-----' (the PEM armour), then removing remaining whitespace. A body we
# cannot EXTRACT at all is only a warning (a single-line <Certificate>QUJD</> style
# would defeat this awk), because the rules below still run on what we did get.
extract_body() {
    awk -v T="$1" '
        $0 ~ "<"T"[ >]" { inb = 1; next }
        $0 ~ "</"T">"    { inb = 0; next }
        inb { line = $0; gsub(/[ \t\r]/, "", line); if (line ~ /^-----/ || line == "") next; printf "%s", line }
    ' "$F" 2>/dev/null
}

# --- Rule 5: base64, replicated exactly --------------------------------------
# This is the rule that was missing, and it is not theoretical: the debug device
# failed with `teesim_km_init_ex: base64: InvalidByte(1887, 61)` — 61 is '=', and
# an offset of 1887 that is NOT in the final 4-char group means the body had more
# data after a padding character. decode_pem() feeds ONE accumulated string per
# element to the `base64` crate's STANDARD engine, whose rules are:
#   * the accumulated length must be a multiple of 4                (InvalidLength)
#   * '=' is legal only inside the FINAL 4-char group, at position 2 or 3
#   * anything else -> InvalidByte(index, byte), index being 0-based
# The old check tested only the character set and length % 4, so a body with an
# interior '=' passed validation and was deployed — and the engine dropped every
# profile with it. Rule 5 predicts that failure here instead, with the same
# wording the TA uses, and names WHICH element is at fault.
#
# One pass, one accumulated buffer per element, exactly like the TA. Prints
# nothing when every body is clean, so --quiet stays quiet on a good keybox.
B64OUT=$(awk '
function ord(c,  t, i) {
  # the printable ASCII range 33..126, in order, so index() gives the byte-32
  t = "!\"#$%&'"'"'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
  i = index(t, c)
  return i > 0 ? 32 + i : -1
}
function audit(tag, acc,   i, n, c, seen) {
  n = length(acc)
  if (n == 0) { printf "FAIL: %s: empty body — the TA reports this as \"empty Certificate\"\n", tag; return 1 }
  if (n % 4 != 0) {
    printf "FAIL: %s: InvalidLength — the accumulated base64 is %d chars, not a multiple of 4 (truncated file?)\n", tag, n
    return 1
  }
  for (i = 1; i <= n; i++) {
    c = substr(acc, i, 1)
    if (c == "=") {
      if (i <= n - 4) {
        printf "FAIL: %s: InvalidByte(%d, 61) — an interior \"=\" (body length %d)\n", tag, i - 1, n
        printf "      context around the offset %d: (redacted — this element can be key material, v3.2.3)\n", i - 1
        printf "      an \"=\" only closes the FINAL 4-char group, so this body holds more than one blob\n"
        return 1
      }
      seen = 1
    } else if (c !~ /[A-Za-z0-9+\/]/) {
      printf "FAIL: %s: InvalidByte(%d, %d) — a non-base64 byte (ord=%d) at this offset\n", tag, i - 1, ord(c), ord(c)
      printf "      context around the offset %d: (redacted — this element can be key material, v3.2.3)\n", i - 1
      return 1
    } else if (seen) {
      printf "FAIL: %s: InvalidByte(%d, %d) — data follows a padding \"=\"\n", tag, i - 1, ord(c)
      return 1
    }
  }
  return 0
}
{ all = all $0 "\n" }
function last_algo(pre,   kp, tp, k, after) {
  kp = 0; tp = 1
  while ((k = index(substr(pre, tp), "<Key")) > 0) { kp = tp + k - 1; tp = kp + 4 }
  if (kp == 0) return "?"
  after = substr(pre, kp)
  if (match(after, /algorithm="[^"]*"/)) {
    after = substr(after, RSTART, RLENGTH)
    return substr(after, 12, length(after) - 12)
  }
  return "?"
}
# <CertificateChain> starts with the same 12 characters as <Certificate>, so a real
# element must be followed by a closing angle bracket or whitespace to count.
function find_cert(all, from,   p, ch) {
  while (1) {
    p = index(substr(all, from), "<Certificate")
    if (!p) return 0
    p = from + p - 1
    ch = substr(all, p + 12, 1)
    if (ch == ">" || ch == " " || ch == "\t" || ch == "\n" || ch == "\r") return p
    from = p + 12
  }
}
END {
  len = length(all); pos = 1
  while (pos <= len) {
    i1 = index(substr(all, pos), "<PrivateKey")
    if (i1) i1 = pos + i1 - 1
    i2 = find_cert(all, pos)
    kind = ""
    if (i1 && (!i2 || i1 < i2)) { st = i1; kind = "PrivateKey" }
    else if (i2) { st = i2; kind = "Certificate" }
    else break
    gt = index(substr(all, st), ">")
    if (!gt) break
    bodyStart = st + gt
    ctag = "</" kind ">"
    ce = index(substr(all, bodyStart), ctag)
    if (!ce) { printf "FAIL: <%s> is never closed (truncated file?)\n", kind; bad++; break }
    body = substr(all, bodyStart, ce - 1)
    pos = bodyStart + ce - 1 + length(ctag)
    algo = last_algo(substr(all, 1, st - 1))
    if (kind == "Certificate") { ncert++; tag = algo " / Certificate #" ncert }
    else tag = algo " / PrivateKey"
    any = 1; n++
    # decode_pem(): per line, trim; skip empty and '-----' armour; drop whitespace
    acc = ""
    m = split(body, lines, "\n")
    for (j = 1; j <= m; j++) {
      ln = lines[j]
      gsub(/^[ \t\r]+/, "", ln); gsub(/[ \t\r]+$/, "", ln)
      if (ln == "" || ln ~ /^-----/) continue
      gsub(/[ \t\r]/, "", ln)
      acc = acc ln
    }
    bad += audit(tag, acc)
  }
  if (!any) { print "warn: no <PrivateKey>/<Certificate> body could be read (unusual layout?)"; exit 0 }
  if (bad == 0) printf "ok  : %d base64 body(ies) decode cleanly (replicated decode_pem)\n", n
  exit (bad > 0 ? 1 : 0)
}
' "$F" 2>/dev/null)
B64RC=$?
# Through say(), so --quiet stays silent on a good keybox while still exiting
# non-zero on a bad one — the same contract every other rule follows.
[ -n "$B64OUT" ] && say "$B64OUT"
if [ "$B64RC" -ne 0 ]; then
    say "      -> the engine cannot build a TA from this keybox."
    exit 1
fi

# Belt and braces: the cheap charset/length test, on the elements we could
# extract. Anything Rule 5 already accepted is necessarily fine, so this only
# catches bodies the replication above never saw.
check_body() {
    body=$(extract_body "$1")
    if [ -z "$body" ]; then
        say "warn: could not extract a <$1> body (unusual layout?) — not counted as a failure"
        return 0
    fi
    case "$body" in
        *[!A-Za-z0-9+/=]*) say "FAIL: <$1> body is not base64 (truncated, encrypted or still obfuscated payload?)"; return 1 ;;
    esac
    if [ $(( ${#body} % 4 )) -ne 0 ]; then
        say "FAIL: <$1> base64 body length ${#body} is not a multiple of 4 (truncated file?)"
        return 1
    fi
    return 0
}

RC=0
check_body PrivateKey || RC=1
check_body Certificate || RC=1
[ "$RC" -eq 0 ] || { say "      -> the engine cannot build a TA from this keybox."; exit 1; }

say "PASS: this keybox is usable by the engine"
exit 0
