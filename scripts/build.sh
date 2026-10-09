#!/bin/bash
# Builds build/CineNotch.app. Signs it with the local "CineNotch Dev" identity when present
# (see scripts/make-dev-cert.sh) so macOS keeps the granted permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/CineNotch.app"
IDENTITY="CineNotch Dev"

swift build -c "$CONFIG" --product CineNotch
swift build -c "$CONFIG" --product NowPlayingBridge
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/CineNotch" "$APP/Contents/MacOS/CineNotch"
cp "$BIN_DIR/libNowPlayingBridge.dylib" "$APP/Contents/Frameworks/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Drawn by scripts/make-icon.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  SIGN="$IDENTITY"
else
  echo "warning: \"$IDENTITY\" not found, signing ad-hoc; permissions will reset on every build." >&2
  echo "         run scripts/make-dev-cert.sh once to fix that." >&2
  SIGN="-"
fi
codesign --force --sign "$SIGN" "$APP/Contents/Frameworks/libNowPlayingBridge.dylib"
codesign --force --sign "$SIGN" "$APP"
echo "built $APP"
