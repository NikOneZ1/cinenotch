#!/bin/bash
# Checks that a built CineNotch.app really comes from the build that just ran, so a release can't
# ship leftover binaries (1.0.0 went out with slices from an old build and no licensing code).
#
#   scripts/verify-build.sh <path/to/CineNotch.app> <build-start-epoch>
#
# Fails when:
#   - the app's executable is missing;
#   - the executable is older than <build-start-epoch> (seconds since 1970, `date +%s`);
#   - Resources/Info.plist has LicensingEnabled true but the executable has no LicenseManager in it;
#   - REQUIRE_ARCHS is set (e.g. "arm64 x86_64") and `lipo -archs` lacks one of them.
# Called by scripts/build.sh before signing and by scripts/release.sh right after the build. Runs on
# its own too, e.g. scripts/verify-build.sh build/CineNotch.app 0 to only check contents.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <app> <build-start-epoch>" >&2
  exit 2
fi
# The app path is taken relative to where the script was run from; everything else to the repo.
case "$1" in
  /*) APP="$1" ;;
  *) APP="$PWD/$1" ;;
esac
START="$2"
cd "$(dirname "$0")/.."
PLIST="${PLIST:-Resources/Info.plist}"

fail() {
  echo "error: build check failed for $APP: $*" >&2
  exit 1
}

case "$START" in
  ''|*[!0-9]*) fail "build start \"$START\" is not a number of seconds." ;;
esac

# Seconds-since-1970 modification time: GNU stat first, else BSD stat (macOS).
mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

# Prints true/false for a boolean key in a plist file.
plist_bool() {
  local value
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    value=$(/usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null || echo false)
  else
    # Fallback for machines without PlistBuddy: the value element right after the key.
    value=$(awk -v key="<key>$2</key>" '
      !found && (i = index($0, key)) { found = 1; $0 = substr($0, i + length(key)); if ($0 !~ /</) next }
      found { if ($0 ~ /^[ \t]*<true\/>/) print "true"; else print "false"; exit }' "$1")
  fi
  [[ "$value" == "true" ]] && echo true || echo false
}

[[ -d "$APP" ]] || fail "the app bundle does not exist."
EXE="$APP/Contents/MacOS/CineNotch"
[[ -f "$EXE" ]] || fail "the executable $EXE is missing."

EXE_TIME=$(mtime "$EXE")
if (( EXE_TIME < START )); then
  fail "the executable is older than this build ($(date -r "$EXE_TIME" 2>/dev/null || echo "$EXE_TIME") < start $START); it is a leftover."
fi

if [[ -n "${REQUIRE_ARCHS:-}" ]]; then
  ARCHS=$(lipo -archs "$EXE" 2>/dev/null) || fail "lipo can't read the executable."
  for arch in $REQUIRE_ARCHS; do
    case " $ARCHS " in
      *" $arch "*) ;;
      *) fail "the executable has architectures \"$ARCHS\" but $arch is required." ;;
    esac
  done
fi

if [[ ! -f "$PLIST" ]]; then
  fail "$PLIST not found, can't tell whether licensing is on."
fi
if [[ "$(plist_bool "$PLIST" LicensingEnabled)" == true ]]; then
  # The Swift type descriptor carries the plain type name, so a build with licensing code has it.
  # grep -c (not -q) so `strings` isn't cut off mid-pipe under pipefail.
  if command -v strings >/dev/null 2>&1; then
    HITS=$(strings -a "$EXE" | grep -c LicenseManager || true)
  else
    HITS=$(grep -a -c LicenseManager "$EXE" || true)
  fi
  if [[ "${HITS:-0}" -eq 0 ]]; then
    fail "LicensingEnabled is true in $PLIST but the executable has no LicenseManager: it was built without the licensing code."
  fi
  echo "verified $EXE: fresh, licensing code present"
else
  echo "verified $EXE: fresh (licensing off, code not required)"
fi
