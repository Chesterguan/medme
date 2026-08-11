#!/usr/bin/env python3
"""
Render plain-text (Chinese) medical report content into a realistic-looking
"scanned/photographed paper report" image using Pillow.

Usage:
    python3 render_scan.py <output.png|.jpg> [--handwriting] [--scale N] < content.txt

The content is read from stdin, one line per row. Long lines are drawn as-is
(callers are expected to keep them under ~40 CJK chars per line for width).

`--scale N` multiplies the type size and margins by N, so the same text renders
at the pixel dimensions of a real full-page capture instead of a canvas
shrink-wrapped around the glyphs. It matters because the OCR engine bands any
image taller than `TILE_CORE_H` (1100 px, see packages/ocr/src/lib.rs) into
overlapping horizontal strips and stitches the results back together. At the
default scale a 17-line report renders about 850 px tall, so it goes through
`predict` as a single frame and the banding/stitching path is never exercised —
while a phone photo of the same A4 page is ~3000x4000 px and always is. Any
evaluation that wants to measure that path has to ask for it explicitly.
"""
import sys
import random
import zlib
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageChops

FONT_CANDIDATES = [
    "/System/Library/Fonts/STHeiti Light.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
]


def load_font(size):
    for path in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def add_scan_grain(img, intensity=18):
    """Blend in light grayscale noise + very slight blur to fake a scan/photo."""
    noise = Image.effect_noise(img.size, intensity).convert("RGB")
    grained = ImageChops.overlay(img, noise)
    blended = Image.blend(img, grained, 0.12)
    return blended.filter(ImageFilter.GaussianBlur(radius=0.4))


def main():
    if len(sys.argv) < 2:
        print("usage: render_scan.py <output.png|.jpg> [--handwriting]", file=sys.stderr)
        sys.exit(1)

    out_path = sys.argv[1]
    handwriting = "--handwriting" in sys.argv[2:]
    scale = 1.0
    if "--scale" in sys.argv[2:]:
        scale = float(sys.argv[sys.argv.index("--scale") + 1])

    text = sys.stdin.read()
    lines = text.split("\n")
    while lines and lines[-1].strip() == "":
        lines.pop()

    # crc32, not the builtin hash(): CPython salts str hashing per process
    # (PEP 456), so `hash(out_path)` hands a *different* seed to every
    # invocation. Rendering the same file twice then produced different grain
    # and a different rotation angle — fine for generating demo data, fatal for
    # an A/B evaluation that renders once per run and compares the numbers
    # across runs. crc32 over the path bytes is stable for a given path forever.
    random.seed(zlib.crc32(out_path.encode("utf-8")))

    font_size = int(24 * scale)
    font = load_font(font_size)
    title_font = load_font(font_size + int(4 * scale))
    line_height = int(font_size * 1.75)
    margin_x = margin_y = int(56 * scale)

    # Measure the widest line with the actual font instead of assuming every
    # character is full-width. CJK glyphs are, but digits, latin and the spaces
    # that pad lab tables into columns are not, so `max_chars * font_size`
    # overshot badly on mixed lines — a 17-line report came out 2066 px wide
    # with the text ending around 1200, i.e. 40% of the page was empty margin.
    # A page that wide also skews the aspect ratio away from the portrait paper
    # the engine actually sees in the field.
    widest = max((font.getlength(l) for l in lines), default=float(font_size * 40))
    width = max(900, int(margin_x * 2 + widest))
    height = margin_y * 2 + line_height * len(lines) + int(30 * scale)

    # Slightly off-white paper tone rather than pure white.
    paper = (250, 249, 245)
    img = Image.new("RGB", (width, height), paper)
    draw = ImageDraw.Draw(img)

    # Outer border to suggest a photographed/scanned page edge.
    draw.rectangle([14, 14, width - 14, height - 14], outline=(90, 90, 90), width=2)
    draw.rectangle([20, 20, width - 20, height - 20], outline=(190, 190, 190), width=1)

    y = margin_y
    for idx, line in enumerate(lines):
        use_font = title_font if idx == 0 else font
        ink = (15, 15, 15)
        if handwriting:
            x = margin_x
            for ch in line:
                jitter_y = random.uniform(-2.2, 2.2)
                jitter_x = random.uniform(-0.6, 0.6)
                draw.text((x + jitter_x, y + jitter_y), ch, font=use_font, fill=(30, 30, 90))
                x += use_font.getlength(ch) if hasattr(use_font, "getlength") else font_size
        else:
            draw.text((margin_x, y), line, font=use_font, fill=ink)
        y += line_height

    img = add_scan_grain(img)

    # Very small random rotation, as if photographed rather than flat-scanned.
    angle = random.uniform(-1.4, 1.4)
    img = img.rotate(angle, expand=True, fillcolor=paper)

    if out_path.lower().endswith((".jpg", ".jpeg")):
        img.convert("RGB").save(out_path, "JPEG", quality=90)
    else:
        img.save(out_path, "PNG")


if __name__ == "__main__":
    main()
