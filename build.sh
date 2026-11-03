#!/bin/bash
# Build Meep.app with swiftc (no Xcode needed) and sign it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Meep.app
WEBRTC=vendor/webrtc   # built by scripts/build-webrtc.sh
[ -f "$WEBRTC/lib/libwebrtc_apm.a" ] || ./scripts/build-webrtc.sh
FFMPEG=vendor/ffmpeg   # built by scripts/build-ffmpeg.sh
[ -x "$FFMPEG/bin/ffmpeg" ] || ./scripts/build-ffmpeg.sh
SPARKLE=vendor/sparkle # downloaded by scripts/fetch-sparkle.sh
[ "$(cat "$SPARKLE/VERSION" 2>/dev/null)" = "$(sed -n 's/^VERSION=//p' scripts/fetch-sparkle.sh)" ] || ./scripts/fetch-sparkle.sh
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp Info.plist "$APP/Contents/Info.plist"
# ffmpeg (LGPL) runs as a separate helper process; its license and configure line go along.
cp "$FFMPEG/bin/ffmpeg" "$APP/Contents/Helpers/ffmpeg"
mkdir -p "$APP/Contents/Resources/ffmpeg"
cp "$FFMPEG/LICENSE" "$FFMPEG/BUILDINFO" "$APP/Contents/Resources/ffmpeg/"
# Sparkle (MIT). Its XPC services are only for sandboxed apps; Meep isn't sandboxed.
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
mkdir -p "$APP/Contents/Resources/Sparkle"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Sparkle/"

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

clang++ -O2 -std=c++17 -target arm64-apple-macos15.0 -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_LIBRARY_IMPL \
  -I "$WEBRTC/include" -c Native/webrtc_aec.cpp -o build/obj/webrtc_aec.o

swiftc -O -swift-version 6 \
  -target arm64-apple-macos15.0 \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework ServiceManagement -framework SwiftUI \
  -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -import-objc-header Native/webrtc_aec.h build/obj/webrtc_aec.o "$WEBRTC/lib/libwebrtc_apm.a" -lc++ \
  Sources/*.swift -o "$APP/Contents/MacOS/Meep"

# A stable signing identity keeps TCC permissions across rebuilds; fall back to ad-hoc.
# Release builds: SIGN_IDENTITY="Developer ID Application: …" (see scripts/release.sh).
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
# Hardened runtime always, so development builds behave like the notarized release.
SIGN=(codesign --force --options runtime --sign "${IDENTITY:--}")
[[ "$IDENTITY" == "Developer ID"* ]] && SIGN+=(--timestamp)
# Nested code first: the app's signature seals the already-signed helper.
"${SIGN[@]}" "$APP/Contents/Helpers/ffmpeg"
SPARKLE_B="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE_B/Autoupdate"
"${SIGN[@]}" "$SPARKLE_B/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" --entitlements Meep.entitlements "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

# Register with LaunchServices so `open meep://…` resolves to this build.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
