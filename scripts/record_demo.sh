#!/usr/bin/env bash
# Records the README demo animation: the app window with the turntable spinning, switching models.
#
#   ./scripts/build-app.sh --install
#   python3 scripts/make_demo_models.py /tmp/3MF-Demo/Models
#   ./scripts/record_demo.sh /tmp/3MF-Demo/Models /tmp/3MF-Demo/video
#   python3 scripts/make_demo_gif.py /tmp/3MF-Demo/video/demo.mov docs/screenshots --segments 0.2-5.2,6-16.9
#
# Terminal needs the Screen Recording permission. Move the mouse pointer off the app window and
# don't touch the mouse or keyboard while it runs (~40 s).
set -uo pipefail

DEMO="$(cd "${1:?demo models folder}" && pwd)"
OUT="${2:?output folder}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/3MF Viewer.app"
BID=io.github.threemfviewer

swiftc -O -o "$OUT/winid" "$ROOT/scripts/winid.swift" || exit 1

# Back up the app's settings; they are restored at the end.
PREFS_BACKUP="$OUT/prefs-backup.plist"
defaults export $BID "$PREFS_BACKUP" 2>/dev/null || true

pkill -x ThreeMFViewer; sleep 1
defaults read $BID 2>/dev/null | grep -o '"NSWindow Frame[^"]*"' | tr -d '"' | while IFS= read -r key; do
  defaults delete $BID "$key"
done
rm -rf "$HOME/Library/Saved Application State/$BID.savedState"
defaults write $BID library.collections -array "$DEMO"
defaults write $BID library.selectedCategory "$DEMO"
defaults write $BID library.expandedCategories -array "$DEMO"
defaults write $BID library.sortOrder name
for key in viewer.showInfo viewer.showColors viewer.showPlate viewer.autoRotate; do defaults write $BID "$key" -bool true; done
defaults write $BID viewer.wireframe -bool false

open -a "$APP" "$DEMO/Retro Rocket.3mf" --args -ApplePersistenceIgnoreState YES
sleep 14   # thumbnails render, window settles
open -a "$APP" "$DEMO/Retro Rocket.3mf"   # bring to front
sleep 2

RECT="$("$OUT/winid" --bounds "3MF Viewer")"
echo "window: $RECT"
rm -f "$OUT/demo.mov"
screencapture -x -v -V 17 -R"$RECT" "$OUT/demo.mov" &
REC=$!
sleep 5.5; open -a "$APP" "$DEMO/Island Terrain.3mf"
sleep 5.5; open -a "$APP" "$DEMO/Gear Train.3mf"
wait $REC

pkill -x ThreeMFViewer
defaults write $BID viewer.autoRotate -bool false
if [ -f "$PREFS_BACKUP" ]; then defaults import $BID "$PREFS_BACKUP"; fi
ls -la "$OUT/demo.mov" && echo "Done: $OUT/demo.mov"
