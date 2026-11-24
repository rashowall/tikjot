#!/bin/bash
# Renders the DMG window background scripts/dmg/background.png (1280×800 tagged 144 dpi = 640×400 pt for a Retina
# window; create-dmg / Finder on macOS 26 show a PNG, not the multi-resolution TIFF) from scripts/dmg/background.html
# with headless Chrome. Re-run after editing the HTML and commit the PNG — release.sh only uses the committed PNG.
# Needs Google Chrome and Python with Pillow.
set -o pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "error: Google Chrome not found" >&2; exit 1; }
PY=python3
"$PY" -c "import PIL" 2>/dev/null || { echo "error: $PY has no Pillow (pip install pillow)" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# render <scale> <out.png>
render() {
  local prof="$TMP/prof$1" shot="$TMP/shot$1.png"
  "$CHROME" --headless --disable-gpu --hide-scrollbars --no-first-run --allow-file-access-from-files \
    --user-data-dir="$prof" --window-size=640,400 --force-device-scale-factor="$1" --virtual-time-budget=3000 \
    --screenshot="$shot" "file://$PWD/background.html" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 80); do [ -s "$shot" ] && sleep 0.5 && break; sleep 0.25; done
  kill $pid 2>/dev/null; pkill -f "$prof" 2>/dev/null
  [ -s "$shot" ] || { echo "error: Chrome render @${1}x failed" >&2; exit 1; }
  # crop to the exact size, drop alpha, tag 144 dpi so Finder shows it at 640×400 pt
  "$PY" - "$shot" "$2" "$1" <<'PY' || exit 1
import sys
from PIL import Image
src, out, s = sys.argv[1], sys.argv[2], int(sys.argv[3])
Image.open(src).convert("RGB").crop((0, 0, 640 * s, 400 * s)).save(out, dpi=(72 * s, 72 * s))
PY
}
render 2 background.png
echo "scripts/dmg/background.png ($(du -k background.png | cut -f1) KB)"
