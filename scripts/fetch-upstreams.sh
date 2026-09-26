#!/usr/bin/env bash
# fetch-upstreams.sh — clone the upstream TEESimulator at the revision pinned in versions.env
# and apply the fusion patches.
#
# Usage: scripts/fetch-upstreams.sh [target-dir]   (default: ./upstream)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
. "$ROOT/versions.env"

TARGET="${1:-$ROOT/upstream}"
mkdir -p "$TARGET"

if [ -d "$TARGET/TEESimulator/.git" ] && [ "$(git -C "$TARGET/TEESimulator" rev-parse HEAD)" = "$TEESIM_REF" ]; then
    echo "== TEESimulator already at $TEESIM_REF"
else
    echo "== Cloning $TEESIM_REPO ($TEESIM_BRANCH @ $TEESIM_REF)"
    rm -rf "$TARGET/TEESimulator"
    # Full history: TEESimulator derives its versionCode from the commit count.
    git clone "$TEESIM_REPO" "$TARGET/TEESimulator"
    git -C "$TARGET/TEESimulator" checkout "$TEESIM_REF"
fi
echo "== Initializing submodules: $TARGET/TEESimulator"
git -C "$TARGET/TEESimulator" submodule update --init --recursive

echo "== Applying fusion patches"
for p in "$ROOT"/patches/teesim/*.patch; do
    git -C "$TARGET/TEESimulator" apply --check "$p"
    git -C "$TARGET/TEESimulator" apply "$p"
    echo "   teesim: $(basename "$p") applied"
done

echo "== Fetching the pinned fingerprint release ($PIF_RELEASE)"
PIF_ZIP="$TARGET/PlayIntegrityFork-$PIF_RELEASE.zip"
PIF_EXPECTED="$PIF_ZIP_SHA256"
if [ -f "$PIF_ZIP" ]; then
    PIF_ACTUAL="$(sha256sum "$PIF_ZIP" | cut -d' ' -f1)"
    if [ "$PIF_ACTUAL" = "$PIF_EXPECTED" ]; then
        echo "== PlayIntegrityFork zip already present and verified"
    else
        echo "!! Checksum mismatch on cached $PIF_ZIP — re-downloading" >&2
        rm -f "$PIF_ZIP"
    fi
fi
if [ ! -f "$PIF_ZIP" ]; then
    curl -fsSL --retry 3 -o "$PIF_ZIP" "$PIF_ZIP_URL"
    PIF_ACTUAL="$(sha256sum "$PIF_ZIP" | cut -d' ' -f1)"
    if [ "$PIF_ACTUAL" != "$PIF_EXPECTED" ]; then
        echo "!! PlayIntegrityFork zip checksum mismatch:" >&2
        echo "   expected $PIF_EXPECTED" >&2
        echo "   actual   $PIF_ACTUAL" >&2
        exit 1
    fi
fi
echo "== Upstream ready under $TARGET"
