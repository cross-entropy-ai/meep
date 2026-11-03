#!/bin/bash
# Downloads Sparkle (the update framework, MIT) into vendor/sparkle: Sparkle.framework, and
# bin/ (generate_keys, sign_update) for scripts/release.sh. Pinned, checked against its SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
OUT=vendor/sparkle

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$TMP/sparkle.tar.xz"
echo "$SHA256  $TMP/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
mkdir -p "$TMP/x"
tar -xf "$TMP/sparkle.tar.xz" -C "$TMP/x"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$TMP/x/Sparkle.framework" "$OUT/Sparkle.framework"
ditto "$TMP/x/bin" "$OUT/bin"
cp "$TMP/x/LICENSE" "$OUT/LICENSE"
echo "$VERSION" > "$OUT/VERSION"
echo "Sparkle $VERSION in $OUT"
