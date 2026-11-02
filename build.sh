#!/bin/bash
# Build MeetingRecorder.app with swiftc (no Xcode needed) and sign it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/MeetingRecorder.app
WEBRTC=vendor/webrtc   # built by scripts/build-webrtc.sh
[ -f "$WEBRTC/lib/libwebrtc_apm.a" ] || ./scripts/build-webrtc.sh
FFMPEG=vendor/ffmpeg   # built by scripts/build-ffmpeg.sh
[ -x "$FFMPEG/bin/ffmpeg" ] || ./scripts/build-ffmpeg.sh
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp Info.plist "$APP/Contents/Info.plist"
# ffmpeg (LGPL) runs as a separate helper process; its license and configure line go along.
cp "$FFMPEG/bin/ffmpeg" "$APP/Contents/Helpers/ffmpeg"
mkdir -p "$APP/Contents/Resources/ffmpeg"
cp "$FFMPEG/LICENSE" "$FFMPEG/BUILDINFO" "$APP/Contents/Resources/ffmpeg/"

# Menu bar icons (loaded at runtime as SVG) and the app icon (.icns from assets/app-icon.png).
cp assets/*.svg "$APP/Contents/Resources/"
# UI translations (Localizable.strings) and permission prompts (InfoPlist.strings), one .lproj per language.
cp -R Resources/*.lproj "$APP/Contents/Resources/"
ICONSET=build/obj/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/app-icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) assets/app-icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

mkdir -p build/obj
clang++ -O2 -std=c++17 -target arm64-apple-macos15.0 -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_LIBRARY_IMPL \
  -I "$WEBRTC/include" -c Native/webrtc_aec.cpp -o build/obj/webrtc_aec.o

swiftc -O -swift-version 5 \
  -target arm64-apple-macos15.0 \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework ServiceManagement -framework SwiftUI \
  -import-objc-header Native/webrtc_aec.h build/obj/webrtc_aec.o "$WEBRTC/lib/libwebrtc_apm.a" -lc++ \
  Sources/*.swift -o "$APP/Contents/MacOS/MeetingRecorder"

# A stable signing identity keeps TCC permissions across rebuilds; fall back to ad-hoc.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
# Nested code first: the app's signature seals the already-signed helper.
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Helpers/ffmpeg"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

# Register with LaunchServices so `open meetingrecorder://…` resolves to this build.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
