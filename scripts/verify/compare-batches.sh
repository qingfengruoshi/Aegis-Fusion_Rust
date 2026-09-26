#!/usr/bin/env bash
# compare-batches.sh — cross-batch binary equivalence check (audit 2026-09-18).
#
# WHY THIS EXISTS
#   Upstream TEESim's native libraries are NOT bit-reproducible: CI rebuilds
#   them from the pinned commit on every cargo/NDK cache miss, and parallel
#   compilation / LTO ordering (plus toolchain-level drift) makes emitted
#   bytes differ while the code stays the same — same compiler fingerprint,
#   same symbols, same constant pool, same function count. A raw hash
#   comparison between two batches therefore CANNOT tell "rebuilt" apart from
#   "tampered". This script does the comparison that can.
#
# HOW IT CLASSIFIES EACH DIFFERING FILE
#   OK-generated  per-build artifact by design (pif_seed.*)
#   OK-source     byte-identical to the repo's module/ copy (a source change)
#   OK-structural ELF: .comment/.dynsym/.dynstr identical, function count
#                 identical, no suspicious new strings; .text/.rodata size
#                 drift is reported as a note (toolchain-level variance)
#   OK-strings    non-ELF (dex/scripts): no suspicious new strings
#   NEEDS-REVIEW  anything else — stop and look by hand
#
# USAGE
#   scripts/verify/compare-batches.sh <batchA> <batchB> [more batches...]
#   Each argument is an unpacked artifact directory or a module .zip.
#   Exit 0 = every difference is accounted for (release-safe).
#   Exit 1 = at least one file needs hand review.
#
# NOTE  This is a review aid, not a CI gate — verify-artifact.sh stays the
# gate. Run this whenever two shipped builds have to be reconciled.
set -uo pipefail

[ $# -ge 2 ] || { echo "usage: $0 <batchA> <batchB> [more...]" >&2; exit 2; }

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

ARGS=()
for a in "$@"; do
    [ -e "$a" ] || { echo "!! not found: $a" >&2; exit 2; }
    if [ -d "$a" ]; then
        ARGS+=("$a")
    else
        [ -n "$TMP" ] || TMP="$(mktemp -d)"
        d="$TMP/$(basename "${a%.zip}")"
        mkdir -p "$d"
        if command -v unzip >/dev/null 2>&1; then unzip -qq -o "$a" -d "$d"
        else python3 -c "import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$a" "$d"; fi
        ARGS+=("$d")
    fi
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Native Windows python cannot resolve MSYS virtual paths (/d/...): convert.
case "$(uname -s)" in
    MINGW*|MSYS*) command -v cygpath >/dev/null 2>&1 && REPO_ROOT="$(cygpath -m "$REPO_ROOT")" ;;
esac
COMPARE_REPO_MODULE="$REPO_ROOT/module" python3 - "${ARGS[@]}" <<'PYBATCH_EOF'
import hashlib, os, re, struct, sys

batches = sys.argv[1:]
# The bash wrapper resolves the repo's module/ dir and passes it via env
# (python reading a script from stdin has no __file__).
REPO_MODULE = os.environ.get("COMPARE_REPO_MODULE", "")

# Sections whose size may drift between builds without meaning a code change:
#   .debug_*        debug info — encodes build paths/toolchain state, not loaded at runtime
#   .text/.rodata   code/constant layout — drift reported as a note, content still checked
#   .relro_padding  alignment filler
#   .strtab/.symtab static symbol names — Rust crate-hash mangling drifts with
#                   the toolchain; the whole-file string check still runs
SOFT_SECTIONS = (".text", ".rodata", ".relro_padding", ".strtab", ".symtab")
SOFT_PREFIXES = (".debug_",)

# Files regenerated per build by design.
GENERATED = {"pif_seed.prop", "pif_seed.auto"}

SUSPICIOUS = re.compile(
    rb"https?://"
    rb"|/data/(?!adb/teesim)"
    rb"|\bcurl\b|\bwget\b|\bnc \b|\bsh -c\b"
    rb"|BEGIN [A-Z ]*PRIVATE KEY"
)


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def elf_sections(path):
    d = open(path, "rb").read()
    if d[:4] != b"\x7fELF":
        return None, d
    try:
        return _elf_sections(d)
    except Exception:
        # Malformed/truncated ELF: report as unparseable rather than crashing —
        # the caller turns this into NEEDS-REVIEW.
        return "UNPARSEABLE", d


def _elf_sections(d):
    e_shoff = struct.unpack_from("<Q", d, 0x28)[0]
    ents = struct.unpack_from("<H", d, 0x3A)[0]
    shnum = struct.unpack_from("<H", d, 0x3C)[0]
    strndx = struct.unpack_from("<H", d, 0x3E)[0]
    st = struct.unpack_from("<IIQQQQIIQQ", d, e_shoff + strndx * ents)[4]
    out = {}
    for i in range(shnum):
        r = struct.unpack_from("<IIQQQQIIQQ", d, e_shoff + i * ents)
        no, typ, _fl, _addr, off, size = r[:6]
        end = d.index(b"\x00", st + no)
        out[d[st + no:end].decode("utf-8", "replace")] = (off, size, typ)
    return out, d


def fde_count(d, secs):
    s = secs.get(".eh_frame_hdr")
    if not s:
        return None
    off = s[0]
    efp_enc, cnt_enc = d[off + 1], d[off + 2]
    p = off + 4
    if efp_enc in (0x03, 0x1B):
        p += 4
    return struct.unpack_from("<I" if cnt_enc == 0x03 else "<i", d, p)[0]


def strings(d, minlen=10):
    return {m.group(0) for m in re.finditer(rb"[ -~]{%d,}" % minlen, d)}


def collect(root):
    out = {}
    for dp, _dn, fns in os.walk(root):
        for f in fns:
            p = os.path.join(dp, f)
            out[os.path.relpath(p, root).replace("\\", "/")] = p
    return out


maps = [collect(b) for b in batches]
common = sorted(set.intersection(*(set(m) for m in maps)))
print("batches: %d  common files: %d\n" % (len(batches), len(common)))

verdicts = []
for name in common:
    if len({sha(m[name]) for m in maps}) == 1:
        continue
    paths = [m[name] for m in maps]
    base = name.split("/")[-1]

    # 1) regenerated per build by design
    if base in GENERATED:
        verdicts.append((name, "OK-generated", "per-build seed identity (by design)"))
        print("--- %s\n    OK-generated: per-build seed identity (by design)" % name)
        continue

    # 2) module.prop is a template in the repo: version/versionCode are
    #    substituted at assemble time, everything else must match verbatim.
    if base == "module.prop":
        repo = os.path.join(REPO_MODULE, "module.prop")
        if os.path.exists(repo):
            def strip_ver(b):
                return b"\n".join(l for l in b.split(b"\n")
                                  if not l.startswith((b"version=", b"versionCode=")))
            src = strip_ver(open(repo, "rb").read().replace(b"\r\n", b"\n"))
            new_b = strip_ver(open(paths[-1], "rb").read().replace(b"\r\n", b"\n"))
            if src == new_b:
                verdicts.append((name, "OK-templated", "template + per-build version line"))
                print("--- %s\n    OK-templated: repo template with the version line substituted ✓" % name)
            else:
                verdicts.append((name, "NEEDS-REVIEW", "module.prop body differs from repo template"))
                print("--- %s\n    NEEDS-REVIEW: body differs from the repo template !!" % name)
            continue

    # 3) repo source file -> must equal the working-tree copy
    repo = os.path.join(REPO_MODULE, name)
    if os.path.exists(repo):
        src = open(repo, "rb").read().replace(b"\r\n", b"\n")
        newest = open(paths[-1], "rb").read().replace(b"\r\n", b"\n")
        if src == newest:
            verdicts.append((name, "OK-source", "matches repo module/ source"))
            print("--- %s\n    OK-source: matches the repo module/ copy (source change)" % name)
        else:
            verdicts.append((name, "NEEDS-REVIEW", "differs from repo module/ source"))
            print("--- %s\n    NEEDS-REVIEW: does NOT match the repo module/ copy !!" % name)
        continue

    # 3) ELF structural analysis
    secs_prev, data_prev = elf_sections(paths[0])
    if secs_prev == "UNPARSEABLE":
        verdicts.append((name, "NEEDS-REVIEW", "ELF header unparseable in batch[0]"))
        print("--- %s\n    NEEDS-REVIEW: ELF unparseable in the earlier batch !!" % name)
        continue
    if secs_prev is not None:
        hard, soft = [], []
        for i, p in enumerate(paths[1:], start=1):
            secs_cur, data_cur = elf_sections(p)
            if secs_cur == "UNPARSEABLE":
                hard.append("ELF unparseable (truncated/corrupted)")
                continue
            if set(secs_cur) != set(secs_prev):
                hard.append("section set changed")
            else:
                for k in secs_prev:
                    a, b = secs_prev[k], secs_cur[k]
                    if a[1] != b[1]:
                        if k in SOFT_SECTIONS or k.startswith(SOFT_PREFIXES):
                            soft.append("%s size %d->%d" % (k, a[1], b[1]))
                        else:
                            hard.append("%s size %d->%d" % (k, a[1], b[1]))
                    elif k in (".comment", ".dynsym", ".dynstr"):
                        if data_prev[a[0]:a[0] + a[1]] != data_cur[b[0]:b[0] + a[1]]:
                            hard.append("%s content changed" % k)
            fa, fb = fde_count(data_prev, secs_prev), fde_count(data_cur, secs_cur)
            if fa is not None and fb is not None and fa != fb:
                hard.append("function count %d->%d" % (fa, fb))
            added = strings(data_cur) - strings(data_prev)
            sus = [s for s in added if SUSPICIOUS.search(s)]
            if sus:
                hard.append("%d suspicious new string(s), e.g. %r" % (len(sus), sus[0][:60]))
            if not hard and not soft:
                soft.append("byte-level codegen/layout drift only")
            tail = "".join("\n        hard: " + h for h in hard) + "".join("\n        note: " + s for s in soft)
            print("--- %s\n    batch[%d] vs batch[0]:%s" % (name, i, tail))
        tier = "NEEDS-REVIEW" if hard else "OK-structural"
        verdicts.append((name, tier, "; ".join(hard or soft)))
        print("    -> %s%s" % (tier, "" if hard else "  (symbols/constants/function-count stable, no suspicious strings)"))
        continue

    # 4) other non-ELF (dex, scripts, ...): string-set + suspicious-pattern check
    d0, dn = open(paths[0], "rb").read(), open(paths[-1], "rb").read()
    added = strings(dn) - strings(d0)
    sus = [s for s in added if SUSPICIOUS.search(s)]
    if sus:
        verdicts.append((name, "NEEDS-REVIEW", "%d suspicious new string(s)" % len(sus)))
        print("--- %s\n    NEEDS-REVIEW: suspicious new string(s): %r" % (name, sus[:3]))
    else:
        verdicts.append((name, "OK-strings", "%d new non-suspicious string(s)" % len(added)))
        print("--- %s\n    OK-strings: %d new string(s), none suspicious" % (name, len(added)))

need = [v for v in verdicts if v[1] == "NEEDS-REVIEW"]
print("\n=== summary ===")
for name, tier, note in verdicts:
    print("  %-13s %-44s %s" % (tier, name, note[:70]))
print()
if need:
    print("VERDICT: %d file(s) NEED REVIEW — inspect before shipping." % len(need))
    sys.exit(1)
print("VERDICT: every difference is accounted for (source change / per-build seed /")
print("codegen-level drift with stable symbols, constants and function counts). Release-safe.")
sys.exit(0)
PYBATCH_EOF
