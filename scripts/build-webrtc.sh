#!/bin/bash
# Build WebRTC AudioProcessing (AEC3) as one static library into vendor/webrtc.
# Source: https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing (v2.x)
# Needs: brew install meson ninja
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
SRC=build/webrtc-src
OUT=vendor/webrtc
REF=${WEBRTC_REF:-d0569cf}   # tested commit (v2.1, 2025-11-10)

if [ ! -d "$SRC" ]; then
  git clone -q https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git "$SRC"
fi
git -C "$SRC" checkout -q "$REF"

cd "$SRC"
# Match the app's minimum macOS (Info.plist LSMinimumSystemVersion / build.sh -target).
export MACOSX_DEPLOYMENT_TARGET=14.2
[ -d build ] || meson setup build --default-library=static --buildtype=release \
  --force-fallback-for=abseil-cpp --prefix="$ROOT/build/webrtc-prefix"
ninja -C build
meson install -C build >/dev/null

cd "$ROOT"
rm -rf "$OUT"; mkdir -p "$OUT/lib"
cp -R build/webrtc-prefix/include/webrtc-audio-processing-2 "$OUT/include"
# absl headers are needed by the APM public headers
cp -R "$SRC"/subprojects/abseil-cpp-*/absl "$OUT/include/absl"
# merge libwebrtc + all abseil static libs into one archive
libtool -static -o "$OUT/lib/libwebrtc_apm.a" build/webrtc-prefix/lib/libwebrtc-audio-processing-2.a \
  $(find "$SRC/build/subprojects" -name 'libabsl_*.a') 2>/dev/null
echo "OK: $OUT/lib/libwebrtc_apm.a"
