#!/usr/bin/env bash
# Installs the latest PadCursor release into /Applications (or ~/Applications) and opens it.
#   curl -fsSL https://raw.githubusercontent.com/baygut/padcursor/main/install.sh | bash
set -euo pipefail

URL="https://github.com/baygut/padcursor/releases/latest/download/PadCursor.zip"
if [ "$(uname -m)" != "arm64" ]; then
  echo "PadCursor needs a Mac with Apple silicon." >&2
  exit 1
fi

DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading PadCursor..."
curl -fsSL "$URL" -o "$TMP/PadCursor.zip"
ditto -x -k "$TMP/PadCursor.zip" "$TMP"

if pgrep -x PadCursor >/dev/null; then
  osascript -e 'quit app "PadCursor"' 2>/dev/null || pkill -x PadCursor || true
  sleep 1
fi
rm -rf "$DEST/PadCursor.app"
mv "$TMP/PadCursor.app" "$DEST/"
echo "Installed to $DEST/PadCursor.app"
open "$DEST/PadCursor.app"
echo "Look for the controller icon in the menu bar. On first launch, allow PadCursor under"
echo "System Settings > Privacy & Security > Accessibility."
