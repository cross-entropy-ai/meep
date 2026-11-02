#!/bin/bash
# Build, sign with Developer ID, notarize and staple Meep.app, then zip it for a
# GitHub release and print the zip's SHA-256 (for the Homebrew cask).
#
# One-time setup: store notarization credentials in the keychain under the profile name used here:
#   xcrun notarytool store-credentials Meep --apple-id <apple-id> --team-id <team-id>
#
# Usage: scripts/release.sh [output-dir]      (NOTARY_PROFILE overrides the profile name)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/release}"
PROFILE="${NOTARY_PROFILE:-Meep}"
APP=build/Meep.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
ZIP="$OUT/Meep-$VERSION-macos-arm64.zip"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[[ "$IDENTITY" == "Developer ID Application"* ]] || { echo "No Developer ID Application identity" >&2; exit 1; }

SIGN_IDENTITY="$IDENTITY" ./build.sh
codesign --verify --deep --strict "$APP"

mkdir -p "$OUT"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute -v "$APP"

# Re-zip so the download carries the stapled ticket (works offline on first launch).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "$ZIP"
shasum -a 256 "$ZIP"
