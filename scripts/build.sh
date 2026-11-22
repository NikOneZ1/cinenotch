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

# Every product must come from this run; scripts/verify-build.sh checks the app against this.
BUILD_START=$(date +%s)

# Seconds-since-1970 modification time: GNU stat first, else BSD stat (macOS).
mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

# True when $1 is a Mach-O binary written since BUILD_START that contains architecture $2.
fresh_slice() {
  local file="$1" arch="$2" archs
  [[ -f "$file" ]] || return 1
  (( $(mtime "$file") >= BUILD_START )) || return 1
  archs=$(lipo -archs "$file" 2>/dev/null) || return 1
  case " $archs " in *" $arch "*) return 0 ;; esac
  return 1
}

# Native architecture for everyday builds: built once and taken from --show-bin-path, as before.
# Releases (UNIVERSAL=1) build arm64 and x86_64 one after the other and copy each arch's products
# into build/slices/<arch>/ right after its own build, then merge those with lipo. Staging matters:
# newer SwiftPM reports one shared .build/out/Products/<Config> for every --triple, so the second
# build overwrites the first, while the classic .build/<arch>-apple-macosx/<config> may hold
# leftovers from an old toolchain (that's how 1.0.0 shipped without its licensing code).
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  ARCHS=(arm64 x86_64)
else
  ARCHS=("")
fi
SLICES="build/slices"
BIN_DIRS=()
for arch in "${ARCHS[@]}"; do
  args=(-c "$CONFIG")
  if [[ -z "$arch" ]]; then
    swift build "${args[@]}" --product CineNotch
    swift build "${args[@]}" --product NowPlayingBridge
    BIN_DIRS+=("$(swift build "${args[@]}" --show-bin-path)")
    continue
  fi

  triple="$arch-apple-macosx14.0"
  args+=(--triple "$triple")
  classic=".build/$arch-apple-macosx/$CONFIG"
  shown=$(swift build "${args[@]}" --show-bin-path)
  # No old product can be picked up: drop the per-arch build dirs and the products in the reported
  # path, so whichever of them has a binary afterwards got it from the build below.
  rm -rf ".build/$arch-apple-macosx" ".build/$triple"
  rm -rf "$shown/CineNotch" "$shown/libNowPlayingBridge.dylib"
  swift build "${args[@]}" --product CineNotch
  swift build "${args[@]}" --product NowPlayingBridge
  shown=$(swift build "${args[@]}" --show-bin-path)

  src=""
  for dir in "$shown" "$classic"; do
    if fresh_slice "$dir/CineNotch" "$arch" && fresh_slice "$dir/libNowPlayingBridge.dylib" "$arch" \
       && [[ -d "$dir/Sparkle.framework" ]]; then
      src="$dir"
      break
    fi
  done
  if [[ -z "$src" ]]; then
    echo "error: no fresh $arch build of CineNotch + libNowPlayingBridge.dylib + Sparkle.framework" >&2
    echo "       in $shown or $classic (built since $(date -r "$BUILD_START" 2>/dev/null || echo "epoch $BUILD_START")). Not using old binaries." >&2
    exit 1
  fi
  # Sparkle comes prebuilt from its package artifact: check it is that one and carries this arch.
  sparkle_bin="$src/Sparkle.framework/Versions/B/Sparkle"
  sparkle_archs=$(lipo -archs "$sparkle_bin" 2>/dev/null || true)
  case " $sparkle_archs " in
    *" $arch "*) ;;
    *) echo "error: $sparkle_bin has \"$sparkle_archs\", no $arch." >&2; exit 1 ;;
  esac
  # Fresh means copied by this build, or byte-identical to the Sparkle that Package.resolved pins.
  artifact=$(find .build/artifacts -path "*/macos-*/Sparkle.framework/Versions/B/Sparkle" 2>/dev/null | sed -n 1p || true)
  if (( $(mtime "$sparkle_bin") < BUILD_START )) && ! { [[ -n "$artifact" ]] && cmp -s "$artifact" "$sparkle_bin"; }; then
    echo "error: $sparkle_bin is older than this build and isn't the resolved Sparkle package${artifact:+ ($artifact)}." >&2
    exit 1
  fi
  echo "$arch: using products from $src"
  rm -rf "${SLICES:?}/$arch"
  mkdir -p "$SLICES/$arch"
  cp "$src/CineNotch" "$src/libNowPlayingBridge.dylib" "$SLICES/$arch/"
  ditto "$src/Sparkle.framework" "$SLICES/$arch/Sparkle.framework"
  BIN_DIRS+=("$SLICES/$arch")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
lipo -create "${BIN_DIRS[@]/%//CineNotch}" -output "$APP/Contents/MacOS/CineNotch"
lipo -create "${BIN_DIRS[@]/%//libNowPlayingBridge.dylib}" -output "$APP/Contents/Frameworks/libNowPlayingBridge.dylib"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  for file in "$APP/Contents/MacOS/CineNotch" "$APP/Contents/Frameworks/libNowPlayingBridge.dylib"; do
    merged=" $(lipo -archs "$file") "
    if [[ "$merged" != *" arm64 "* || "$merged" != *" x86_64 "* ]]; then
      echo "error: $file is not universal (archs:$merged)." >&2
      exit 1
    fi
  done
fi
# Sparkle, for in-app updates. Its XPC services only matter to sandboxed apps, so they stay out.
ditto "${BIN_DIRS[0]}/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/CineNotch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Drawn by scripts/make-icon.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Refuse to sign an app that isn't from this build or lacks the licensing code it should have.
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  REQUIRE_ARCHS="arm64 x86_64" ./scripts/verify-build.sh "$APP" "$BUILD_START"
else
  ./scripts/verify-build.sh "$APP" "$BUILD_START"
fi

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

# Hardened runtime on every build, so everyday builds behave like the notarized one. Its library
# validation wants the app and Sparkle signed by one team, which only a Developer ID certificate
# has, so local builds (the self-signed "CineNotch Dev" or ad hoc) are allowed to load Sparkle.
ENTITLEMENTS=Resources/CineNotch.entitlements
if [[ "$SIGN" != "Developer ID Application:"* ]]; then
  ENTITLEMENTS=build/CineNotch-local.entitlements
  cp Resources/CineNotch.entitlements "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
fi
FLAGS=(--force --options runtime --sign "$SIGN")
[[ "${TIMESTAMP:-0}" == 1 ]] && FLAGS+=(--timestamp)
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${FLAGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${FLAGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${FLAGS[@]}" "$SPARKLE"
codesign "${FLAGS[@]}" "$APP/Contents/Frameworks/libNowPlayingBridge.dylib"
codesign "${FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
echo "built $APP"
