#!/usr/bin/env bash
# Builds "3MF Viewer.app" from the Swift package.
#
#   ./scripts/build-app.sh                # release build for this Mac's architecture
#   UNIVERSAL=1 ./scripts/build-app.sh    # arm64 + x86_64 (needs full Xcode)
#   ./scripts/build-app.sh --zip          # also produce build/3MF-Viewer-<version>.zip
#
# Environment: VERSION (default: latest git tag or 0.1.0), BUNDLE_ID, SIGN_IDENTITY (default: ad-hoc "-").
set -euo pipefail

APP_NAME="3MF Viewer"
EXECUTABLE="ThreeMFViewer"
BUNDLE_ID="${BUNDLE_ID:-io.github.threemfviewer}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

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

echo "==> Building $EXECUTABLE $VERSION (${BUILD_ARGS[*]})"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

APP="$ROOT/build/$APP_NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp "Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R Packaging/*.lproj "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD__/$BUILD_NUMBER/g" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    "Packaging/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (identity: $SIGN_IDENTITY)"
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null \
  || codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

if [[ "${1:-}" == "--zip" ]]; then
  ZIP="$ROOT/build/3MF-Viewer-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  echo "==> $ZIP"
fi

echo "==> Done: $APP"
