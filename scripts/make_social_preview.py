#!/usr/bin/env python3
"""Builds docs/social-preview.png (1280×640) — the image GitHub shows when the repo link is shared.

    python3 scripts/make_social_preview.py <captures-dir> <fonts-dir> docs/social-preview.png

<captures-dir> holds rocket.png from scripts/take_screenshots.sh; <fonts-dir> holds Inter-400/600/800.ttf.
Upload the result in GitHub → Settings → General → Social preview.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compose_screenshots as cs  # noqa: E402  (shared backdrop / scaling helpers)

SRC, FONTS, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
cs.SRC = SRC
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 2  # draw at 2× and downscale for crisp text
W, H = 1280 * S, 640 * S


def font(weight, size):
    return ImageFont.truetype(os.path.join(FONTS, f"Inter-{weight}.ttf"), size * S)


canvas = cs.backdrop((W, H), radius=0)

# App window, bleeding off the right edge.
shot = cs.scale(cs.load("rocket.png"), 820 * S)
canvas.alpha_composite(shot, (W - int(shot.width * 0.80), int(H * 0.5 - shot.height * 0.5) + 40 * S))

# Soft dark veil behind the text for contrast.
veil = Image.new("RGBA", (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(veil)
for x in range(0, 700 * S, 4):
    a = int(120 * max(0, 1 - x / (700 * S)) ** 1.6)
    d.rectangle([x, 0, x + 4, H], fill=(10, 16, 36, a))
canvas.alpha_composite(veil)

icon = Image.open(os.path.join(ROOT, "Packaging", "AppIcon.png")).convert("RGBA")
icon = icon.resize((150 * S, 150 * S), Image.LANCZOS)
x0 = 64 * S
canvas.alpha_composite(icon, (x0 - 14 * S, 70 * S))

d = ImageDraw.Draw(canvas)
d.text((x0, 238 * S), "3MF Viewer", font=font(800, 74), fill=(255, 255, 255, 255))
tag = ["The fast, native macOS viewer", "for 3D-printing models."]
for i, line in enumerate(tag):
    d.text((x0, 336 * S + i * 42 * S), line, font=font(400, 31), fill=(226, 236, 245, 255))

chips = ["Bambu / Orca / Prusa colours", "Quick Look", "Free & open source"]
layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
ld = ImageDraw.Draw(layer)
f = font(600, 19)
cx, cy = x0, 448 * S
placed = []
for label in chips:
    w = ld.textlength(label, font=f)
    if cx + w + 32 * S > 640 * S:  # wrap to the next row
        cx, cy = x0, cy + 52 * S
    box = [cx, cy, cx + w + 32 * S, cy + 40 * S]
    ld.rounded_rectangle(box, radius=20 * S, fill=(255, 255, 255, 30), outline=(255, 255, 255, 90), width=S)
    placed.append((cx + 16 * S, cy + 9 * S, label))
    cx = box[2] + 12 * S
canvas.alpha_composite(layer)
d = ImageDraw.Draw(canvas)
for tx, ty, label in placed:
    d.text((tx, ty), label, font=f, fill=(255, 255, 255, 255))

d.text((x0, H - 64 * S), "github.com/1300023/3mf-viewer", font=font(400, 20), fill=(190, 210, 225, 255))

out = canvas.convert("RGB").resize((1280, 640), Image.LANCZOS)
os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)
out.save(OUT, optimize=True)
print(OUT, os.path.getsize(OUT) // 1024, "KB")
