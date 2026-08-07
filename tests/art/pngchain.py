# Proves the PNG-to-transparency chain end to end: a paletted PNG with
# #FF00FF in palette slot 255 must convert, through the same gfx2next
# invocation the kit's build uses, to a file whose slot 255 packs to the
# reserved value and whose pixels still read index 255.
#
# WHY THIS EXISTS. Every other transparency check in this repo starts
# after the conversion. The L2 holes card is written byte by byte and
# never sees a PNG, so it proves the interpreter renders holes but not
# that an author can produce one. This is the only test covering the
# step in between - gfx2next preserving palette indices. If a future
# gfx2next remapped them, every author's transparency would silently
# stop working and nothing else here would fail.
#
# The reserved values are read from src/nextdaad.inc rather than
# hardcoded, so this cannot drift from the interpreter.

import os
import re
import subprocess
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GFX = os.path.join(ROOT, "tools", "gfx2next", "gfx2next.exe")
WORK = os.path.join(ROOT, "tests", "out", "pngchain")

TRANSPARENT_SRC = (255, 0, 255)      # the colour authors paint
WIDTH = HEIGHT = 16


def reserved_from_inc():
    """Read L2_TRANSP_COLOUR and L2_TRANSP_INDEX from the interpreter."""
    inc = os.path.join(ROOT, "src", "nextdaad.inc")
    with open(inc, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    colour = re.search(r"(?m)^\s*L2_TRANSP_COLOUR\s+equ\s+\$([0-9A-Fa-f]+)", text)
    index = re.search(r"(?m)^\s*L2_TRANSP_INDEX\s+equ\s+(\d+)", text)
    if not colour or not index:
        sys.exit("pngchain: cannot read the reserved values from src/nextdaad.inc "
                 "- the constants moved, fix this fixture")
    return int(colour.group(1), 16), int(index.group(1))


def build_png(path, transparent_slot):
    """16x16 paletted PNG. Slot `transparent_slot` holds the transparent
    source colour; row 0 is painted with it; row 1 uses slot 7."""
    pal = []
    for i in range(256):
        pal += [i, (i * 3) % 256, (i * 7) % 256]
    pal[transparent_slot * 3:transparent_slot * 3 + 3] = list(TRANSPARENT_SRC)
    im = Image.new("P", (WIDTH, HEIGHT), 1)
    im.putpalette(pal)
    px = im.load()
    for x in range(WIDTH):
        px[x, 0] = transparent_slot
        px[x, 1] = 7
    im.save(path)


def convert(png_path, out_name):
    """Run gfx2next exactly as authoring-kit/lib/gfx.bat does."""
    out_path = os.path.join(WORK, out_name)
    if os.path.exists(out_path):
        os.unlink(out_path)
    proc = subprocess.run([GFX, "-bitmap", "-pal-embed", png_path, out_path],
                          cwd=WORK, capture_output=True, text=True)
    if proc.returncode != 0 or not os.path.exists(out_path):
        sys.exit("pngchain: gfx2next failed: %s %s" % (proc.stdout, proc.stderr))
    with open(out_path, "rb") as f:
        return f.read()


def main():
    if not os.path.exists(GFX):
        sys.exit("pngchain: gfx2next not found at %s" % GFX)
    os.makedirs(WORK, exist_ok=True)
    transp_colour, transp_index = reserved_from_inc()

    # --- the chain that must work -------------------------------------
    good_png = os.path.join(WORK, "good.png")
    build_png(good_png, transp_index)
    data = convert(good_png, "good.nxi")

    if len(data) != 512 + WIDTH * HEIGHT:
        sys.exit("pngchain: expected %d bytes, got %d"
                 % (512 + WIDTH * HEIGHT, len(data)))

    slot_byte0 = data[transp_index * 2]
    if slot_byte0 != transp_colour:
        sys.exit("pngchain: slot %d packed to $%02X, expected $%02X - the "
                 "transparent source colour no longer converts to the reserved "
                 "value" % (transp_index, slot_byte0, transp_colour))

    pixels = data[512:]
    row0 = pixels[0:WIDTH]
    if any(p != transp_index for p in row0):
        sys.exit("pngchain: row 0 should be all index %d, got %r - gfx2next no "
                 "longer preserves palette indices, so authored transparency is "
                 "broken" % (transp_index, sorted(set(row0))))

    row1 = pixels[WIDTH:WIDTH * 2]
    if any(p != 7 for p in row1):
        sys.exit("pngchain: row 1 should be all index 7, got %r - indices are "
                 "being remapped" % (sorted(set(row1)),))

    print("pngchain: #%02X%02X%02X in slot %d survives conversion as index %d, "
          "packing to $%02X" % (TRANSPARENT_SRC + (transp_index, transp_index,
                                                   transp_colour)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
