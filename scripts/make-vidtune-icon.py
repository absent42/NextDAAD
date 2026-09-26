#!/usr/bin/env python3
"""Draw authoring-kit/lib/vidtune/vidtune.ico (16-256 px) from theme colours.

Usage: python scripts/make-vidtune-icon.py [preview.png]
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "authoring-kit" / "lib" / "vidtune" / "vidtune.ico"
SIZES = (16, 24, 32, 48, 64, 128, 256)
SS = 1024  # supersampled canvas

PANEL = (18, 20, 24, 255)
EDGE = (255, 255, 255, 36)
ACCENT = (90, 140, 255, 255)
METER = ((79, 176, 106, 255), (217, 164, 65, 255), (213, 69, 63, 255))


def draw(small):
    """small: fewer, heavier shapes that survive 16-24 px."""
    im = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    pad = 16 if small else 40
    d.rounded_rectangle((pad, pad, SS - pad, SS - pad), radius=180,
                        fill=PANEL, outline=EDGE, width=24)
    # play triangle, centroid on the vertical centre line
    if small:
        tri = [(355, 170), (355, 650), (815, 410)]
    else:
        tri = [(380, 180), (380, 600), (780, 390)]
    d.polygon(tri, fill=ACCENT)
    # meter: three bars rising left to right
    base = 860 if small else 850
    width = 200 if small else 170
    gap = 50 if small else 55
    heights = (90, 140, 190) if small else (80, 130, 180)
    x = (SS - (3 * width + 2 * gap)) // 2
    for colour, h in zip(METER, heights):
        d.rounded_rectangle((x, base - h, x + width, base), radius=20, fill=colour)
        x += width + gap
    return im


def main():
    big, small = draw(False), draw(True)
    frames = [(small if s <= 24 else big).resize((s, s), Image.LANCZOS) for s in SIZES]
    frames[-1].save(OUT, format="ICO", sizes=[(s, s) for s in SIZES],
                    append_images=frames[:-1])
    print(f"wrote {OUT}")
    if len(sys.argv) > 1:
        sheet = Image.new("RGBA", (sum(SIZES) + 10 * len(SIZES), 256), (40, 40, 40, 255))
        x = 0
        for f in frames:
            sheet.alpha_composite(f, (x, 0))
            x += f.width + 10
        sheet.save(sys.argv[1])
        print(f"wrote {sys.argv[1]}")


if __name__ == "__main__":
    main()
