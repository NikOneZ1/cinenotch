#!/bin/bash
# Builds build/CineNotch.app. Signs it with the local "CineNotch Dev" identity when present
# (see scripts/make-dev-cert.sh) so macOS keeps the granted permissions across rebuilds.
# scripts/release.sh reuses it with IDENTITY (Developer ID), UNIVERSAL=1 and TIMESTAMP=1.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/CineNotch.app"
DEV_IDENTITY="CineNotch Dev"
IDENTITY="${IDENTITY:-$DEV_IDENTITY}"

# Native architecture for everyday builds; arm64 + x86_64 merged with lipo for releases.
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  TRIPLES=(arm64-apple-macosx14.0 x86_64-apple-macosx14.0)
else
  TRIPLES=("")
fi
BIN_DIRS=()
for triple in "${TRIPLES[@]}"; do
  args=(-c "$CONFIG")
  [[ -n "$triple" ]] && args+=(--triple "$triple")
  swift build "${args[@]}" --product CineNotch
  swift build "${args[@]}" --product NowPlayingBridge
  BIN_DIRS+=("$(swift build "${args[@]}" --show-bin-path)")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
lipo -create "${BIN_DIRS[@]/%//CineNotch}" -output "$APP/Contents/MacOS/CineNotch"
lipo -create "${BIN_DIRS[@]/%//libNowPlayingBridge.dylib}" -output "$APP/Contents/Frameworks/libNowPlayingBridge.dylib"
# Sparkle, for in-app updates. Its XPC services only matter to sandboxed apps, so they stay out.
ditto "${BIN_DIRS[0]}/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/CineNotch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Drawn by scripts/make-icon.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  SIGN="$IDENTITY"
elif [[ "$IDENTITY" == "$DEV_IDENTITY" ]]; then
  echo "warning: \"$IDENTITY\" not found, signing ad-hoc; permissions will reset on every build." >&2
  echo "         run scripts/make-dev-cert.sh once to fix that." >&2
  SIGN="-"
else
  echo "error: signing identity \"$IDENTITY\" not found in the keychain." >&2
  exit 1
fi

# Hardened runtime on every build, so everyday builds behave like the notarized one.
FLAGS=(--force --options runtime --sign "$SIGN")
[[ "${TIMESTAMP:-0}" == 1 ]] && FLAGS+=(--timestamp)
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${FLAGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${FLAGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${FLAGS[@]}" "$SPARKLE"
codesign "${FLAGS[@]}" "$APP/Contents/Frameworks/libNowPlayingBridge.dylib"
codesign "${FLAGS[@]}" --entitlements Resources/CineNotch.entitlements "$APP"
echo "built $APP"
