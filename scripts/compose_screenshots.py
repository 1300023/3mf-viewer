#!/usr/bin/env python3
"""Turns raw window captures (screencapture -l <window>) into the README images in docs/screenshots.

    python3 scripts/compose_screenshots.py <captures-dir> docs/screenshots

Captures come from scripts/take_screenshots.sh: rocket, terrain, gears, chess, lamp, knot, quicklook (.png). Output is WebP (small, sharp, supported by GitHub).
"""
import os
import sys

import numpy as np

from PIL import Image, ImageDraw, ImageFilter

SRC = sys.argv[1] if len(sys.argv) > 1 else "shots"
DST = sys.argv[2] if len(sys.argv) > 2 else "docs/screenshots"
os.makedirs(DST, exist_ok=True)


ALIASES = {"rocket.png": "light-rocket.png", "terrain.png": "light-terrain.png", "vase.png": "light-vase.png",
           "gears.png": "dark-gears.png", "chess.png": "dark-chess.png", "lamp.png": "dark-lamp.png",
           "knot.png": "dark-knot.png", "quicklook.png": "quicklook-qlmanage.png"}


def load(name):
    path = os.path.join(SRC, name)
    if not os.path.exists(path) and name in ALIASES:
        path = os.path.join(SRC, ALIASES[name])
    return Image.open(path).convert("RGBA")


def scale(im, width):
    """High-quality resize that keeps soft shadows clean (premultiplied alpha)."""
    h = round(im.height * width / im.width)
    return im.convert("RGBa").resize((width, h), Image.LANCZOS).convert("RGBA")


def gradient(size, top, bottom, diagonal=0.35):
    w, h = size
    ys, xs = np.mgrid[0:h, 0:w]
    t = np.clip((ys / h) * (1 - diagonal) + (xs / w) * diagonal, 0, 1)[..., None]
    rgb = np.array(top, float) + (np.array(bottom, float) - np.array(top, float)) * t
    rgba = np.concatenate([rgb, np.full((h, w, 1), 255.0)], axis=2).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def glow(size, center, radius, color, alpha):
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = center
    d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=color + (alpha,))
    return layer.filter(ImageFilter.GaussianBlur(radius / 2.2))


def rounded(im, radius):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width - 1, im.height - 1], radius=radius, fill=255)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(im, (0, 0), mask)
    return out


def with_shadow(im, radius=28, offset=18, opacity=110, margin=70):
    w, h = im.width + 2 * margin, im.height + 2 * margin
    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([margin, margin + offset, margin + im.width, margin + im.height + offset],
                                            radius=radius, fill=(0, 0, 0, opacity))
    shadow = shadow.filter(ImageFilter.GaussianBlur(margin / 2.5))
    shadow.alpha_composite(im, (margin, margin))
    return shadow


def backdrop(size, radius=48):
    bg = gradient(size, (27, 38, 76), (14, 118, 128))
    bg.alpha_composite(glow(size, (int(size[0] * 0.22), int(size[1] * 0.18)), int(size[0] * 0.28), (120, 170, 255), 70))
    bg.alpha_composite(glow(size, (int(size[0] * 0.85), int(size[1] * 0.9)), int(size[0] * 0.25), (60, 220, 190), 60))
    # faint build-plate grid
    grid = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(grid)
    step = max(40, size[0] // 30)
    for x in range(0, size[0], step):
        d.line([(x, 0), (x, size[1])], fill=(255, 255, 255, 12), width=2)
    for y in range(0, size[1], step):
        d.line([(0, y), (size[0], y)], fill=(255, 255, 255, 12), width=2)
    bg.alpha_composite(grid)
    return rounded(bg, radius)


def save(im, name, quality=90):
    path = os.path.join(DST, name)
    im.save(path, "WEBP", quality=quality, method=6)
    print(f"{path}: {im.size[0]}x{im.size[1]}, {os.path.getsize(path) // 1024} KB")


def quicklook_panel():
    raw = load("quicklook.png")
    # Inner content of the Quick Look panel (drops the "[DEBUG]" title bar that qlmanage adds).
    content = raw.crop((56, 108, 1656, 1308))
    return rounded(content, 26)


# ---------------------------------------------------------------- hero

def hero():
    W, H = 2400, 1400
    canvas = backdrop((W, H))
    back = scale(load("terrain.png"), 1560)
    front = scale(load("rocket.png"), 1560)
    canvas.alpha_composite(back, (W - back.width + 30, -10))
    canvas.alpha_composite(front, (-30, H - front.height + 40))
    save(rounded(canvas, 48), "hero.webp", quality=88)


# ---------------------------------------------------------------- gallery cards

def card(name, width=1600, pad=90):
    shot = scale(load(name), width - 2 * pad + 60)  # captures include ~30 px of shadow per side
    h = shot.height + 2 * pad - 60
    canvas = backdrop((width, h), radius=36)
    canvas.alpha_composite(shot, ((width - shot.width) // 2, (h - shot.height) // 2 + 10))
    return rounded(canvas, 36)


def quicklook_card(width=1600):
    panel = with_shadow(scale(quicklook_panel(), 1080), radius=22, offset=16, opacity=130, margin=60)
    h = 1118
    canvas = backdrop((width, h), radius=36)
    canvas.alpha_composite(panel, ((width - panel.width) // 2, (h - panel.height) // 2 + 8))
    return rounded(canvas, 36)


if __name__ == "__main__":
    hero()
    for src, dst in [("gears.png", "filaments.webp"),
                     ("terrain.png", "color-groups.webp"),
                     ("chess.png", "multi-object.webp"),
                     ("lamp.png", "high-poly.webp"),
                     ("knot.png", "smooth.webp")]:
        save(card(src), dst)
    save(quicklook_card(), "quick-look.webp")
