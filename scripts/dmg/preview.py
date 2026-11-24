"""Preview of the DMG window (no Finder): background.png + the two icons and labels at the slots from
scripts/dmg-settings.py, under an approximate title bar. Writes .build/dmg-preview.png.
Usage (repo root): python3 scripts/dmg/preview.py
"""
import os
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

S = 2  # render at @2x
W, H, TITLE = 640, 400, 28
SLOTS = {"tikjot": (160, 190), "Applications": (480, 190)}
ICON, TEXT = 128, 13

bg_tiff = Image.open("scripts/dmg/background.png")
pass  # background.png is already 1280×800
bg = bg_tiff.convert("RGB")
assert bg.size == (W * S, H * S), bg.size

app_icon = Image.open("App/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png").convert("RGBA")
tmp = os.path.join(tempfile.mkdtemp(), "apps.png")
subprocess.run(["sips", "-s", "format", "png", "-Z", str(ICON * S),
                "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns",
                "--out", tmp], check=True, capture_output=True)
icons = {"tikjot": app_icon, "Applications": Image.open(tmp).convert("RGBA")}

win = Image.new("RGB", (W * S, (H + TITLE) * S), "#ECEAF0")
win.paste(bg, (0, TITLE * S))
d = ImageDraw.Draw(win)
for i, c in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]):  # traffic lights
    x, y = (20 + i * 20) * S, (TITLE // 2) * S
    d.ellipse((x - 6 * S, y - 6 * S, x + 6 * S, y + 6 * S), fill=c)
try:
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", TEXT * S)
    tfont = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 13 * S)
except OSError:
    font = tfont = ImageFont.load_default()
d.text((W * S // 2, TITLE * S // 2), "tikjot", fill="#4D4A57", font=tfont, anchor="mm")

for name, (cx, cy) in SLOTS.items():
    ic = icons[name].resize((ICON * S, ICON * S), Image.LANCZOS)
    win.paste(ic, ((cx - ICON // 2) * S, (TITLE + cy - ICON // 2) * S), ic)
    d.text((cx * S, (TITLE + cy + ICON // 2 + 4) * S), name, fill="#17152A", font=font, anchor="mt")

os.makedirs(".build", exist_ok=True)
win.save(".build/dmg-preview.png")
print(".build/dmg-preview.png")
