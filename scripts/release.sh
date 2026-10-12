#!/bin/bash
# Builds build/CineNotch.dmg for download: a universal app signed with Developer ID, notarized
# and stapled, inside a signed, notarized and stapled disk image with an Applications shortcut.
#
# Needs the "Developer ID Application" identity in the keychain and notarytool credentials:
#   locally: a keychain profile, "cinenotch-notary" by default, saved once with
#            xcrun notarytool store-credentials cinenotch-notary --key AuthKey_….p8 --key-id … --issuer …
#   on CI:   NOTARY_KEY (path to the .p8), NOTARY_KEY_ID and NOTARY_ISSUER.
# RESUME=1 picks up build/CineNotch.app that was already submitted (say, the wait was cut off):
# it skips building and notarizing the app, staples its ticket and carries on with the image.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/CineNotch.app"
DMG="build/CineNotch.dmg"
PROFILE="${NOTARY_PROFILE:-cinenotch-notary}"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}"
if [[ -z "$IDENTITY" ]]; then
  echo "error: no \"Developer ID Application\" identity in the keychain." >&2
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)
echo "CineNotch $VERSION ($BUILD), signed by $IDENTITY"

if [[ -n "${NOTARY_KEY:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  AUTH=(--keychain-profile "$PROFILE")
fi
# Fail now rather than after the build. macOS hides the saved profile while the screen is locked.
if ! xcrun notarytool history "${AUTH[@]}" >/dev/null 2>&1; then
  echo "error: notarytool can't sign in (no \"$PROFILE\" profile, or the screen is locked)." >&2
  exit 1
fi

# Submits a file for notarization, waits for Apple's verdict and prints the log if it's rejected.
notarize() {
  local result id status
  echo "notarizing $(basename "$1")…"
  result=$(xcrun notarytool submit "$1" "${AUTH[@]}" --wait --output-format json)
  id=$(plutil -extract id raw -o - - <<<"$result")
  status=$(plutil -extract status raw -o - - <<<"$result")
  echo "  $status ($id)"
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" "${AUTH[@]}" >&2
    exit 1
  fi
}

if [[ "${RESUME:-0}" != 1 ]]; then
  # 1. The app: universal, hardened runtime, secure timestamp.
  IDENTITY="$IDENTITY" UNIVERSAL=1 TIMESTAMP=1 ./scripts/build.sh
  codesign --verify --strict --deep "$APP"

  # 2. Notarize the app itself, so it opens even offline once copied out of the image.
  ZIP="build/CineNotch-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
fi
xcrun stapler staple -q "$APP"

# 3. The disk image: the app plus a shortcut to drag it onto.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/CineNotch.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "CineNotch" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple -q "$DMG"

# 4. What Gatekeeper will say on a user's Mac.
spctl --assess --type execute "$APP" && echo "app: accepted by Gatekeeper"
spctl --assess --type open --context context:primary-signature "$DMG" && echo "dmg: accepted by Gatekeeper"
echo "done: $DMG ($(du -h "$DMG" | cut -f1)), sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
