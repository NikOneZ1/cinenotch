#!/bin/bash
# Builds build/CineNotch.app. Signs it with the local "CineNotch Dev" identity when present
# (see scripts/make-dev-cert.sh) so macOS keeps the granted permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/CineNotch.app"
IDENTITY="CineNotch Dev"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CineNotch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CineNotch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Drawn by scripts/make-icon.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "warning: \"$IDENTITY\" not found, signing ad-hoc; permissions will reset on every build." >&2
  echo "         run scripts/make-dev-cert.sh once to fix that." >&2
  codesign --force --sign - "$APP"
fi
echo "built $APP"
