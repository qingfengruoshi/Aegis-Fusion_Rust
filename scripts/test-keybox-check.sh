#!/bin/sh
# test-keybox-check.sh -- regression suite for module/keybox-check.sh
#
# WHY. keybox-check.sh is a *replica* of the engine, not a heuristic: it mirrors
# rust/teesim-km/src/attest.rs decode_pem() plus the `base64` crate's STANDARD
# rules, in the order the TA evaluates them. So the contract this suite pins is
# one-directional and strict:
#
#     a fixture the ENGINE would reject  -> keybox-check.sh must reject it
#     a fixture the ENGINE would accept  -> keybox-check.sh must accept it
#
# If a case here starts failing because keybox-check.sh changed, the honest
# question is "what does decode_pem() actually do?" -- never "make the fixture
# pass". Read the Rust before touching a case.
#
# Every fixture is synthetic: dummy base64 only, no real key material.
# Usage: sh scripts/test-keybox-check.sh
# Exit : 0 all cases pass | 1 at least one case failed

set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$HERE/module/keybox-check.sh"
TMP=$(mktemp -d 2>/dev/null) || TMP="${TMPDIR:-/tmp}/keybox-check.$$"
mkdir -p "$TMP" || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
LAST_OUT=""

note() { printf '  %s\n' "$*"; }
bump_pass() { PASS=$((PASS + 1)); note "PASS $1"; }
bump_fail() {
    FAIL=$((FAIL + 1))
    note "FAIL $1"
    printf '%s\n' "$LAST_OUT" | sed 's/^/         /'
}

# run <label> <want-rc> [args...]
run() {
    _label="$1"; _want="$2"; shift 2
    LAST_OUT=$(sh "$CHECK" "$@" 2>&1)
    _rc=$?
    if [ "$_rc" -eq "$_want" ]; then
        bump_pass "$_label (rc=$_rc)"
    else
        LAST_OUT="(exit $_rc, want $_want)
$LAST_OUT"
        bump_fail "$_label"
    fi
}

# want_grep <label> <literal>
want_grep() {
    if printf '%s\n' "$LAST_OUT" | grep -qF -- "$2"; then
        bump_pass "$1"
    else
        LAST_OUT=$(printf 'output lacks %s\n%s' "$2" "$LAST_OUT")
        bump_fail "$1"
    fi
}

# --- synthetic bodies ---------------------------------------------------------
# 32 chars: 'ABCDEF' x4 in base64. 32 % 4 == 0, no padding, no interior '='.
B32="QUJDREVGQUJDREVGQUJDREVGQUJD"
# 24 chars, also padding-free.
B24="QUJDREVGQUJDREVGQUJDREVG"
# 30 chars -> 30 % 4 == 2 -> InvalidLength, which is exactly what a truncated
# download looks like.
B30="QUJDREVGQUJDREVGQUJDREVGQUJDE"

ARM_BEGIN_PK="-----BEGIN RSA PRIVATE KEY-----"
ARM_END_PK="-----END RSA PRIVATE KEY-----"
ARM_BEGIN_CERT="-----BEGIN CERTIFICATE-----"
ARM_END_CERT="-----END CERTIFICATE-----"

# cert_block <indent> <body>            -- a well-formed <Certificate>
cert_block() {
    printf '%s<Certificate format="pem">\n' "$1"
    printf '%s%s\n' "$1" "$ARM_BEGIN_CERT"
    for _l in $2; do printf '%s%s\n' "$1" "$_l"; done
    printf '%s%s\n' "$1" "$ARM_END_CERT"
    printf '%s</Certificate>\n' "$1"
}

# keybox <algo> <key-body> <cert1-block> <cert2-block> ...
# Builds a full document; each cert block is passed through verbatim so a case
# can splice in a deliberately malformed element.
keybox() {
    _algo="$1"; _kb="$2"; shift 2
    printf '<Keybox DeviceID="suite">\n'
    printf '<Key algorithm="%s">\n' "$_algo"
    printf '<PrivateKey format="pem">\n%s\n%s\n%s\n</PrivateKey>\n' \
        "$ARM_BEGIN_PK" "$_kb" "$ARM_END_PK"
    printf '<CertificateChain>\n'
    printf '%s' "$*"
    printf '</CertificateChain>\n</Key>\n</Keybox>\n'
}

C1=$(cert_block "" "$B32")
C2=$(cert_block "" "$B32")

# --- good boxes ---------------------------------------------------------------
keybox rsa "$B32" "$C1" "$C2" >"$TMP/ok-rsa.xml"
keybox ecdsa "$B32" "$C1" "$C2" >"$TMP/ok-ec.xml"
keybox ecdsa "$B32" "$C1" "$C2" "$(cert_block "" "$B24")" >"$TMP/ok-three.xml"

# --- bad boxes ----------------------------------------------------------------
# a chain with only ONE certificate: the TA needs >= 2
keybox rsa "$B32" "$C1" >"$TMP/onecert.xml"

# no algorithm attribute at all
{
    printf '<Keybox DeviceID="suite">\n<Key>\n'
    printf '<PrivateKey format="pem">\n%s\n%s\n%s\n</PrivateKey>\n' \
        "$ARM_BEGIN_PK" "$B32" "$ARM_END_PK"
    printf '<CertificateChain>\n%s%s</CertificateChain>\n</Key>\n</Keybox>\n' "$C1" "$C2"
} >"$TMP/noalgo.xml"

# truncated body: 30 chars, 30 %% 4 == 2
keybox rsa "$B32" "$(cert_block "" "$B30")" "$C2" >"$TMP/truncated.xml"

# a stray character that is not in the base64 alphabet
keybox rsa "$B32" "$(cert_block "" "QUJDREVG#UJDREVGQUJDREVGQUJD")" "$C2" >"$TMP/stray.xml"

# THE FIELD CASE. The debug device logged
#     teesim_km_init_ex: base64: InvalidByte(1887, 61)
# 61 is '='; an offset of 1887 lands in the MIDDLE of the accumulated buffer, so
# one element carried data AFTER a padding character. The real-world cause is two
# blobs concatenated inside a single <Certificate> (a re-download appended to an
# older body instead of replacing it). Reproduce it byte-for-byte: 1887 'A's, a
# '=', then more blob.
{
    awk 'BEGIN { for (i = 0; i < 1887; i++) printf "A"; print "=" }'
    printf '%s\n' "$B24"
} >"$TMP/twopem-body.txt"
TWOPEM_BODY=$(cat "$TMP/twopem-body.txt")
keybox rsa "$B32" \
    "$(cert_block "" "$TWOPEM_BODY")" "$C2" >"$TMP/twopem.xml"

# an HTML error page saved under a .xml name
printf '<!DOCTYPE html>\n<html><body>404 Not Found</body></html>\n' >"$TMP/html.xml"

# --- armour placement ---------------------------------------------------------
# The engine strips armour PER LINE: a line is dropped only when it STARTS with
# '-----'. So where the closing armour sits decides whether the body decodes.
# BEGIN sharing the tag's line is fine (the remainder is its own line).
{
    printf '<Keybox DeviceID="suite">\n<Key algorithm="rsa">\n'
    printf '<PrivateKey format="pem">%s\n%s\n%s\n</PrivateKey>\n' \
        "$ARM_BEGIN_PK" "$B32" "$ARM_END_PK"
    printf '<CertificateChain>\n'
    printf '<Certificate format="pem">%s\n%s\n%s</Certificate>\n' \
        "$ARM_BEGIN_CERT" "$B32" "$ARM_END_CERT"
    printf '<Certificate format="pem">%s\n%s\n%s</Certificate>\n' \
        "$ARM_BEGIN_CERT" "$B32" "$ARM_END_CERT"
    printf '</CertificateChain>\n</Key>\n</Keybox>\n'
} >"$TMP/armour-tagline.xml"

# ...but armour that shares a line with the LAST data line is NOT stripped, so the
# dashes are fed to the decoder and it fails. This is a real keybox you cannot
# use, however healthy it looks in an editor.
{
    printf '<Keybox DeviceID="suite">\n<Key algorithm="rsa">\n'
    printf '<PrivateKey format="pem">\n%s\n%s\n</PrivateKey>\n' "$B32" "$ARM_END_PK"
    printf '<CertificateChain>\n'
    printf '<Certificate format="pem">%s\n%s%s</Certificate>\n' \
        "$ARM_BEGIN_CERT" "$B32" "$ARM_END_CERT"
    printf '<Certificate format="pem">\n%s\n%s\n%s\n</Certificate>\n' \
        "$ARM_BEGIN_CERT" "$B32" "$ARM_END_CERT"
    printf '</CertificateChain>\n</Key>\n</Keybox>\n'
} >"$TMP/armour-glued.xml"

# --- unreadable inputs --------------------------------------------------------
: >"$TMP/empty.xml"
MISSING="$TMP/definitely-not-here.xml"

# =============================================================================
printf '== keybox-check.sh regression vs the engine ==\n'

run "clean rsa box"                        0 "$TMP/ok-rsa.xml"
run "clean ec-only box (RKP style)"        0 "$TMP/ok-ec.xml"
run "clean 3-cert padding-free chain"      0 "$TMP/ok-three.xml"

run "single-cert chain is rejected"        1 "$TMP/onecert.xml"
run "missing algorithm attribute"          1 "$TMP/noalgo.xml"
run "truncated body (30 chars, len % 4)"   1 "$TMP/truncated.xml"
run "stray non-base64 character"           1 "$TMP/stray.xml"
run "HTML error page saved as .xml"        1 "$TMP/html.xml"

run "interior '=' -- the field case"       1 "$TMP/twopem.xml"
want_grep "  ...quotes InvalidByte(1887, 61)" "InvalidByte(1887, 61)"
want_grep "  ...names the offending element"  "Certificate #1"

run "armour on the tag line (engine OK)"    0 "$TMP/armour-tagline.xml"
run "armour glued to the body (engine rejects)" 1 "$TMP/armour-glued.xml"
want_grep "  ...explains the interior dash"  "non-base64 byte"

run "missing file"                         2 "$MISSING"
run "empty file"                           2 "$TMP/empty.xml"
run "no argument"                          2

# --quiet must be silent on a good box and still exit non-zero on a bad one.
run "--quiet on a good box"                0 "$TMP/ok-rsa.xml" --quiet
if [ -z "$LAST_OUT" ]; then
    bump_pass "  ...and prints nothing"
else
    bump_fail "  ...and prints nothing"
fi
run "--quiet on a bad box"                 1 "$TMP/twopem.xml" --quiet
if [ -z "$LAST_OUT" ]; then
    bump_pass "  ...and still prints nothing"
else
    bump_fail "  ...and still prints nothing"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
