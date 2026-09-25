#!/usr/bin/env bash
# Captures the README screenshots of the installed app, then composes docs/screenshots.
#
#   python3 scripts/make_demo_models.py /tmp/3MF-Demo/Models
#   ./scripts/take_screenshots.sh /tmp/3MF-Demo/Models /tmp/3MF-Demo/shots
#   python3 scripts/compose_screenshots.py /tmp/3MF-Demo/shots docs/screenshots
#
# Terminal needs the Screen Recording permission (System Settings → Privacy & Security).
# Don't touch the mouse while it runs (~1.5 min). Your app settings are restored at the end.
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
for key in viewer.showInfo viewer.showColors viewer.showPlate; do defaults write $BID "$key" -bool true; done
defaults write $BID viewer.wireframe -bool false

open -a "$APP" "$DEMO/Retro Rocket.3mf" --args -ApplePersistenceIgnoreState YES
sleep 15   # let the list thumbnails render

shoot() { # model name, output name
  open -a "$APP" "$DEMO/$1.3mf"
  sleep 5
  screencapture -x -l"$("$OUT/winid" "3MF Viewer")" "$OUT/$2.png"
  echo "captured $2"
}
shoot "Retro Rocket" rocket
shoot "Island Terrain" terrain
shoot "Twisted Vase" vase
shoot "Gear Train" gears
shoot "Chess Pieces" chess
shoot "Trefoil Knot" knot
shoot "Wave Lamp Shade" lamp
pkill -x ThreeMFViewer

qlmanage -p "$DEMO/Retro Rocket.3mf" >/dev/null 2>&1 &
sleep 6
W="$("$OUT/winid" qlmanage)"
[ "$W" != "0" ] && screencapture -x -l"$W" "$OUT/quicklook.png" && echo "captured quicklook"
pkill -x qlmanage

# Restore settings.
if [ -f "$PREFS_BACKUP" ]; then defaults import $BID "$PREFS_BACKUP"; fi
echo "Done: $OUT"
