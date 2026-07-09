#!/usr/bin/env python3
"""
Render plain-text (Chinese) medical report content into a realistic-looking
"scanned/photographed paper report" image using Pillow.

Usage:
    python3 render_scan.py <output.png|.jpg> [--handwriting] < content.txt

The content is read from stdin, one line per row. Long lines are drawn as-is
(callers are expected to keep them under ~40 CJK chars per line for width).
"""
import sys
import random
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

    text = sys.stdin.read()
    lines = text.split("\n")
    while lines and lines[-1].strip() == "":
        lines.pop()

    random.seed(hash(out_path) & 0xFFFFFFFF)

    font_size = 24
    font = load_font(font_size)
    title_font = load_font(font_size + 4)
    line_height = int(font_size * 1.75)
    margin_x, margin_y = 56, 56

    max_chars = max((len(l) for l in lines), default=40)
    width = max(900, margin_x * 2 + max_chars * (font_size + 4))
    height = margin_y * 2 + line_height * len(lines) + 30

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
