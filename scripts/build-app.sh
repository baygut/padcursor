#!/usr/bin/env bash
# Builds dist/PadCursor.app (Apple silicon) and dist/PadCursor.zip.
# Optional: SIGN_IDENTITY="Developer ID Application: ..." to sign,
#           NOTARY_PROFILE=<notarytool keychain profile> to notarize and staple.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/PadCursor"
APP=dist/PadCursor.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PadCursor"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"   # ad-hoc, for local builds
fi
codesign --verify --strict "$APP"

ditto -c -k --keepParent "$APP" dist/PadCursor.zip
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit dist/PadCursor.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm dist/PadCursor.zip
  ditto -c -k --keepParent "$APP" dist/PadCursor.zip
fi
echo "built $APP ($VERSION, build $BUILD)"
