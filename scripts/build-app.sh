#!/usr/bin/env bash
# Builds "3MF Viewer.app" (with its Quick Look extensions) from the Swift package.
#
#   ./scripts/build-app.sh                  # release build for this Mac's architecture
#   UNIVERSAL=1 ./scripts/build-app.sh      # arm64 + x86_64 (needs full Xcode)
#   ./scripts/build-app.sh --zip            # also produce build/3MF-Viewer-<version>.zip
#   ./scripts/build-app.sh --install        # also copy to /Applications and register Quick Look
#
# Environment: VERSION (default: latest git tag or 0.1.0), BUNDLE_ID, SIGN_IDENTITY (default: ad-hoc "-").
set -euo pipefail

APP_NAME="3MF Viewer"
EXECUTABLE="ThreeMFViewer"
BUNDLE_ID="${BUNDLE_ID:-io.github.threemfviewer}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

ZIP=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --zip) ZIP=1 ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")"
fi
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

BUILD_ARGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "==> Building $APP_NAME $VERSION (${BUILD_ARGS[*]})"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

fill_plist() { # template → destination
  sed -e "s/__VERSION__/$VERSION/g" \
      -e "s/__BUILD__/$BUILD_NUMBER/g" \
      -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
      "$1" > "$2"
}

sign() { # path [entitlements]
  local args=(--force --timestamp=none --options runtime --sign "$SIGN_IDENTITY")
  if [[ -n "${2:-}" ]]; then args+=(--entitlements "$2"); fi
  codesign "${args[@]}" "$1"
}

APP="$ROOT/build/$APP_NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp "Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R Packaging/*.lproj "$APP/Contents/Resources/"
fill_plist "Packaging/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Quick Look extensions: <name>.appex = executable + Info.plist, sandboxed.
add_extension() { # bundle-name executable packaging-dir
  local appex="$APP/Contents/PlugIns/$1.appex"
  mkdir -p "$appex/Contents/MacOS" "$appex/Contents/Resources"
  cp "$BIN_DIR/$2" "$appex/Contents/MacOS/$2"
  cp -R Packaging/*.lproj "$appex/Contents/Resources/"
  fill_plist "Packaging/$3/Info.plist" "$appex/Contents/Info.plist"
  sign "$appex" "Packaging/Extension.entitlements"
}
echo "==> Adding Quick Look extensions"
add_extension "3MF Quick Look" "ThreeMFQuickLook" "QuickLookPreview"
add_extension "3MF Thumbnails" "ThreeMFThumbnail" "QuickLookThumbnail"

echo "==> Signing (identity: $SIGN_IDENTITY)"
sign "$APP"
codesign --verify --deep --strict "$APP"

if [[ "$ZIP" == "1" ]]; then
  ZIP_PATH="$ROOT/build/3MF-Viewer-$VERSION.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_PATH"
  echo "==> $ZIP_PATH"
fi

if [[ "$INSTALL" == "1" ]]; then
  DEST="/Applications/$APP_NAME.app"
  echo "==> Installing to $DEST"
  pkill -x "$EXECUTABLE" >/dev/null 2>&1 || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  # Make sure only the installed copy provides the Quick Look extensions.
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f -R -trusted "$DEST"
  pluginkit -a "$DEST/Contents/PlugIns/3MF Quick Look.appex" || true
  pluginkit -a "$DEST/Contents/PlugIns/3MF Thumbnails.appex" || true
  qlmanage -r >/dev/null 2>&1 || true
  qlmanage -r cache >/dev/null 2>&1 || true
  echo "==> Installed. Select a .3mf file in Finder and press Space."
fi

echo "==> Done: $APP"
