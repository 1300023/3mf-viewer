#!/usr/bin/env python3
"""Generates Packaging/AppIcon.icns (and a PNG preview) with Pillow.

    pip install pillow && python3 scripts/make_icon.py
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

S = 1024
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "Packaging")


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def squircle_mask(size, inset, radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    return mask


def main():
    inset = 100
    body = S - 2 * inset

    # Background gradient (top-left deep blue → bottom-right teal).
    bg = Image.new("RGBA", (S, S))
    top, bottom = (28, 38, 74, 255), (14, 116, 128, 255)
    px = bg.load()
    for y in range(S):
        for x in range(S):
            t = min(1.0, max(0.0, (0.75 * y + 0.25 * x) / S))
            px[x, y] = lerp(top, bottom, t)

    # Build plate grid in perspective.
    grid = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    g = ImageDraw.Draw(grid)
    cx, cy = S / 2, 640
    iso = lambda u, v: (cx + (u - v) * math.cos(math.radians(30)), cy + (u + v) * math.sin(math.radians(30)))
    half, step = 300, 60
    for i in range(-half, half + 1, step):
        g.line([iso(i, -half), iso(i, half)], fill=(255, 255, 255, 60), width=4)
        g.line([iso(-half, i), iso(half, i)], fill=(255, 255, 255, 60), width=4)

    # Isometric cube ("printed part").
    cube = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    c = ImageDraw.Draw(cube)
    a = 190  # half edge in plate units
    h = 250  # height in pixels
    p = lambda u, v, z=0: (iso(u, v)[0], iso(u, v)[1] - z)
    top_face = [p(-a, -a, h), p(a, -a, h), p(a, a, h), p(-a, a, h)]
    left_face = [p(-a, a, h), p(a, a, h), p(a, a, 0), p(-a, a, 0)]
    right_face = [p(a, -a, h), p(a, a, h), p(a, a, 0), p(a, -a, 0)]

    # Soft shadow under the cube.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon([p(-a, -a), p(a, -a), p(a, a), p(-a, a)], fill=(0, 0, 0, 140))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))

    c.polygon(left_face, fill=(232, 110, 44, 255))
    c.polygon(right_face, fill=(196, 78, 28, 255))
    c.polygon(top_face, fill=(255, 158, 84, 255))
    # Layer lines on the side faces.
    for z in range(22, h, 22):
        c.line([p(-a, a, z), p(a, a, z)], fill=(255, 255, 255, 38), width=3)
        c.line([p(a, -a, z), p(a, a, z)], fill=(0, 0, 0, 34), width=3)
    # Edge highlights.
    c.line(top_face + [top_face[0]], fill=(255, 214, 170, 255), width=6, joint="curve")
    c.line([p(a, a, h), p(a, a, 0)], fill=(255, 190, 140, 200), width=5)

    art = Image.alpha_composite(bg, grid)
    art = Image.alpha_composite(art, shadow)
    art = Image.alpha_composite(art, cube)

    # Glossy top highlight.
    gloss = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(gloss).ellipse([-200, -520, S + 200, 420], fill=(255, 255, 255, 26))
    art = Image.alpha_composite(art, gloss)

    mask = squircle_mask(S, inset, 185)
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # Drop shadow of the whole tile.
    tile_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(tile_shadow).rounded_rectangle([inset, inset + 14, S - inset, S - inset + 14], radius=185, fill=(0, 0, 0, 110))
    tile_shadow = tile_shadow.filter(ImageFilter.GaussianBlur(18))
    icon = Image.alpha_composite(icon, tile_shadow)
    icon.paste(art, (0, 0), mask)

    os.makedirs(OUT_DIR, exist_ok=True)
    icon.save(os.path.join(OUT_DIR, "AppIcon.png"))
    icon.save(os.path.join(OUT_DIR, "AppIcon.icns"),
              sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("written", os.path.join(OUT_DIR, "AppIcon.icns"))


if __name__ == "__main__":
    main()
