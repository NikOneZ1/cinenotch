#!/bin/bash
# Builds build/CineNotch.dmg for download: a universal app signed with Developer ID, notarized
# and stapled, inside a signed, notarized and stapled disk image: drag the app onto Applications.
# Also builds the in-app update: build/CineNotch-<version>.zip and build/appcast.xml, signed with
# the Sparkle key. Publish the zip with the GitHub release and appcast.xml on cinenotch.cam.
#
# Needs the "Developer ID Application" identity in the keychain and notarytool credentials:
#   locally: a keychain profile, "cinenotch-notary" by default, saved once with
#            xcrun notarytool store-credentials cinenotch-notary --key AuthKey_….p8 --key-id … --issuer …
#   on CI:   NOTARY_KEY (path to the .p8), NOTARY_KEY_ID and NOTARY_ISSUER.
# The Sparkle key comes from the keychain (account "cinenotch", see generate_keys), or from
# SPARKLE_KEY_FILE on CI. RELEASE_NOTES may point to a text file of "- " lines for the update window.
# RESUME=1 picks up build/CineNotch.app that was already submitted (say, the wait was cut off):
# it skips building and notarizing the app, staples its ticket and carries on with the image.
# VERIFY_ONLY=1 runs only the prechecks, the universal build and scripts/verify-build.sh, then stops:
# no Developer ID or notarytool credentials needed (signs with IDENTITY or the local dev identity,
# like scripts/build.sh), and nothing is notarized, stapled or uploaded.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/CineNotch.app"
DMG="build/CineNotch.dmg"
PROFILE="${NOTARY_PROFILE:-cinenotch-notary}"
VERIFY_ONLY="${VERIFY_ONLY:-0}"
if [[ "$VERIFY_ONLY" == 1 && "${RESUME:-0}" == 1 ]]; then
  echo "error: VERIFY_ONLY=1 builds the app, so it can't be combined with RESUME=1." >&2
  exit 1
fi
if [[ "$VERIFY_ONLY" == 1 ]]; then
  IDENTITY="${IDENTITY:-CineNotch Dev}"
else
  IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "error: no \"Developer ID Application\" identity in the keychain." >&2
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)
echo "CineNotch $VERSION ($BUILD), signed by $IDENTITY"

# Licensing (docs/LICENSING.md): a build with it switched on must carry the key that checks the tokens.
LICENSING=$(/usr/libexec/PlistBuddy -c "Print LicensingEnabled" Resources/Info.plist 2>/dev/null || echo false)
if [[ "$LICENSING" == "true" ]]; then
  LICENSE_KEY=$(/usr/libexec/PlistBuddy -c "Print LicensePublicKey" Resources/Info.plist 2>/dev/null || true)
  if [[ -z "$LICENSE_KEY" ]]; then
    echo "error: LicensingEnabled is true but LicensePublicKey is empty in Resources/Info.plist." >&2
    exit 1
  fi
  echo "licensing: ON (public key ${LICENSE_KEY:0:8}…)"
else
  echo "licensing: off (free build)"
fi

if [[ -n "${NOTARY_KEY:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  AUTH=(--keychain-profile "$PROFILE")
fi
# Fail now rather than after the build. macOS hides the saved profile while the screen is locked.
if [[ "$VERIFY_ONLY" != 1 ]] && ! xcrun notarytool history "${AUTH[@]}" >/dev/null 2>&1; then
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
  # 1. The app: universal, hardened runtime, secure timestamp (not for VERIFY_ONLY's local signature).
  START=$(date +%s)
  TS=1
  [[ "$VERIFY_ONLY" == 1 ]] && TS=0
  IDENTITY="$IDENTITY" UNIVERSAL=1 TIMESTAMP="$TS" ./scripts/build.sh
  # The guard, again, before anything leaves this Mac: fresh executable, both archs, licensing code.
  REQUIRE_ARCHS="arm64 x86_64" ./scripts/verify-build.sh "$APP" "$START"
  codesign --verify --strict --deep "$APP"
  if [[ "$VERIFY_ONLY" == 1 ]]; then
    echo "VERIFY_ONLY: build and guard passed, nothing notarized or published"
    exit 0
  fi

  # 2. Notarize the app itself, so it opens even offline once copied out of the image.
  ZIP="build/CineNotch-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
else
  # Resuming: no build ran, so only the contents are checked (any age, both archs, licensing code).
  REQUIRE_ARCHS="arm64 x86_64" ./scripts/verify-build.sh "$APP" 0
fi
xcrun stapler staple -q "$APP"

# The update Sparkle downloads: the stapled app, zipped, and an appcast pointing at the release.
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
ZIP="build/CineNotch-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
  SIGNATURE=$("$SPARKLE_BIN/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$ZIP")
else
  SIGNATURE=$("$SPARKLE_BIN/sign_update" --account cinenotch "$ZIP")
fi
if [[ -n "${RELEASE_NOTES:-}" ]]; then
  NOTES="<description><![CDATA[<ul>$(sed -n 's/^- \(.*\)/<li>\1<\/li>/p' "$RELEASE_NOTES" | tr -d '\n')</ul>]]></description>"
else
  NOTES="<sparkle:releaseNotesLink>https://github.com/NikOneZ1/cinenotch/releases/tag/v$VERSION</sparkle:releaseNotesLink>"
fi
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>CineNotch</title>
    <link>https://cinenotch.cam/appcast.xml</link>
    <item>
      <title>CineNotch $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      $NOTES
      <enclosure url="https://github.com/NikOneZ1/cinenotch/releases/download/v$VERSION/CineNotch-$VERSION.zip" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

# 3. The disk image: the app on the left, Applications on the right, the "drag it in" arrow
#    between them (scripts/dmg-settings.py). dmgbuild writes the window layout itself, no Finder.
DMGBUILD="build/dmgbuild-venv/bin/dmgbuild"
if [[ ! -x "$DMGBUILD" ]]; then
  python3 -m venv build/dmgbuild-venv
  build/dmgbuild-venv/bin/pip install -q "dmgbuild==1.6.7"
fi
rm -f "$DMG"
"$DMGBUILD" -s scripts/dmg-settings.py -D app="$APP" CineNotch "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple -q "$DMG"

# 4. What Gatekeeper will say on a user's Mac.
spctl --assess --type execute "$APP" && echo "app: accepted by Gatekeeper"
spctl --assess --type open --context context:primary-signature "$DMG" && echo "dmg: accepted by Gatekeeper"
echo "done: $DMG ($(du -h "$DMG" | cut -f1)), sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "      $ZIP and build/appcast.xml for the in-app update"
