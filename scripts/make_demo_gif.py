#!/usr/bin/env python3
"""Turns the screen recording from scripts/record_demo.sh into docs/screenshots/demo.gif (+ demo.webp).

    pip install pillow numpy imageio-ffmpeg
    python3 scripts/make_demo_gif.py demo.mov docs/screenshots --segments 0.2-5.2,11.6-16.9

--segments  comma-separated time ranges (seconds) to keep, e.g. to skip a model switch.
--filter    optional "file.py:function" called as function(frame: PIL.Image, segment_index) -> PIL.Image
            on every full-resolution frame (handy for touch-ups such as hiding the mouse pointer).

The window gets rounded corners and a shadow and is placed on the same backdrop as the other README
images. The GIF uses one optimised palette (ffmpeg palettegen/paletteuse); the animated WebP is smaller.
"""
import argparse
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

import imageio_ffmpeg
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compose_screenshots as cs  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("movie")
ap.add_argument("out_dir")
ap.add_argument("--width", type=int, default=880, help="width of the window inside the animation")
ap.add_argument("--fps", type=int, default=15)
ap.add_argument("--segments", default="0-16", help="time ranges to keep, e.g. 0.2-5.2,11.6-16.9")
ap.add_argument("--filter", default=None)
args = ap.parse_args()

frame_filter = None
if args.filter:
    path, func = args.filter.rsplit(":", 1)
    spec = importlib.util.spec_from_file_location("frame_filter", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    frame_filter = getattr(module, func)

ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
work = tempfile.mkdtemp(prefix="demo-gif-")
out_frames = os.path.join(work, "frames")
os.makedirs(out_frames)

# 1. Full-resolution frames of every segment.
raw = []  # (path, segment index)
for index, segment in enumerate(args.segments.split(",")):
    start, end = (float(v) for v in segment.split("-"))
    seg_dir = os.path.join(work, f"seg{index}")
    os.makedirs(seg_dir)
    subprocess.run([ffmpeg, "-loglevel", "error", "-ss", str(start), "-t", str(end - start), "-i", args.movie,
                    "-vf", f"fps={args.fps}", os.path.join(seg_dir, "%04d.png")], check=True)
    raw += [(os.path.join(seg_dir, name), index) for name in sorted(os.listdir(seg_dir))]
print(f"{len(raw)} frames")

# 2. Touch-up, scale, rounded window + shadow on the backdrop.
first = Image.open(raw[0][0])
ww = args.width
wh = round(first.height * ww / first.width)
radius = max(6, round(ww * 10 / 1240))
mask = Image.new("L", (ww, wh), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, ww - 1, wh - 1], radius=radius, fill=255)
pad_x, pad_y = round(ww * 0.07), round(wh * 0.08)
canvas_size = (ww + 2 * pad_x, wh + 2 * pad_y)
shadow = cs.with_shadow(Image.new("RGBA", (ww, wh), (0, 0, 0, 0)), radius=radius, offset=round(wh * 0.02),
                        opacity=120, margin=pad_x // 2)
base = cs.backdrop(canvas_size, radius=0)
base.alpha_composite(shadow, (pad_x - pad_x // 2, pad_y - pad_x // 2))
for number, (path, segment) in enumerate(raw):
    window = Image.open(path).convert("RGB")
    if frame_filter:
        window = frame_filter(window, segment)
    window = window.resize((ww, wh), Image.LANCZOS)
    frame = base.copy()
    frame.paste(window, (pad_x, pad_y), mask)
    frame.convert("RGB").save(os.path.join(out_frames, f"{number:04d}.png"))

# 3. GIF with one optimised palette + an animated WebP.
os.makedirs(args.out_dir, exist_ok=True)
gif = os.path.join(args.out_dir, "demo.gif")
webp = os.path.join(args.out_dir, "demo.webp")
pattern = os.path.join(out_frames, "%04d.png")
subprocess.run([ffmpeg, "-loglevel", "error", "-y", "-framerate", str(args.fps), "-i", pattern, "-filter_complex",
                "split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];"
                "[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle", "-loop", "0", gif], check=True)
subprocess.run([ffmpeg, "-loglevel", "error", "-y", "-framerate", str(args.fps), "-i", pattern,
                "-c:v", "libwebp", "-lossless", "0", "-q:v", "80", "-loop", "0", "-an", webp], check=True)
for path in (gif, webp):
    print(f"{path}: {os.path.getsize(path) / 1024 / 1024:.1f} MB, {canvas_size[0]}x{canvas_size[1]}")
shutil.rmtree(work)
