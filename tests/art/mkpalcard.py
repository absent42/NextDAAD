# Full-colour Layer 2 reference card for the 256-colour text fixture
# (tests\palette.dsf).
#
# Produces tests\out\palcard.nx2, which tests\build-tests.ps1 -Palette
# stages as sd\PALETTE\001.NX2 - the one picture the fixture loads with
# PICTURE 1 and draws with DISPLAY 0.
#
# WHAT THIS CARD IS FOR. The fixture exercises text ink and paper across
# 0-255. This card puts the SAME 256 colours on Layer 2, directly above
# the text, so a mismatch between a swatch and the text below it is a
# real defect: swatch n is palette index n (16x16 grid, row r column c =
# index r*16+c), the IDENTITY palette (entry i encodes RRRGGGBB = i,
# ninth blue bit = B1 OR B0) - exactly what pal_colour computes for text
# colour 16-255 and what the core derives on an 8-bit palette write.
#
# TWO SWATCHES ARE NOT THE IDENTITY COLOUR, both from Layer 2
# transparency, not faults:
#   INDEX 255 is the reserved transparent entry, so its swatch is a
#     hole onto the tilemap - the fixture clears the card's footprint to
#     red first, so a working hole shows red and a failure shows black.
#   INDEX 227 encodes to $E3 (L2_TRANSP_COLOUR) under the identity rule,
#     so it is written as $E7 here - same $E3/$E7 dodge as mkl2holes.py's
#     card. Swatches 227 and 231 therefore show the same colour; text
#     INK 227 is unaffected since the tilemap palette isn't rewritten.
#
# SIZE. 320x128 as .NX2: 320-wide covers the same screen area as the
# 80x32 text grid (1 cell = 4x8 picture pixels), so the card occupies
# tilemap rows 0-15 across all 80 columns, top-aligned, text window at
# row 16. .NX2 also routes the blit through gfx_row_scatter320 (a CPU
# column scatter) instead of the .NXI cards' gfx_row_copy256/DMA path,
# so this card exercises the scatter path specifically.
#
# Generated, not committed - a byte-exact function of the constants
# below, the same rule tests\art\mkl2card.py follows.

import os
import sys

WIDTH = 320
HEIGHT = 128

GRID = 16                       # 16 x 16 swatches covering all 256 indices
SWATCH_W = WIDTH // GRID        # 20 pixels
SWATCH_H = HEIGHT // GRID       # 8 pixels

TRANSPARENT = 255               # L2_TRANSP_INDEX
TRANSP_COLOUR = 0xE3            # L2_TRANSP_COLOUR
TRANSP_DODGE = 0xE7             # L2_TRANSP_DODGE - what l2_palette_load rewrites $E3 to


def entry(i):
    """The two palette bytes for index i under the identity rule.

    byte 0 = RRRGGGBB, byte 1 = blue LSB in bit 0 and the Layer 2
    priority bit in bit 7, which stays clear. The ninth blue bit is
    B1 OR B0 - the rule the core applies on an 8-bit write and the one
    pal_colour reproduces for text.
    """
    if i == TRANSPARENT:
        # Byte 1 is 0, not the identity rule's blue LSB: l2_pal9_stamp
        # (src\overlay2.asm) rewrites this entry on every picture load as
        # $E3 then 0, because bit 7 of the second write is the Layer 2
        # colour PRIORITY bit and a priority bit on the transparent entry
        # would be actively harmful. Matching it keeps the file a
        # description of what is displayed rather than of a value the
        # loader replaces underneath it.
        return TRANSP_COLOUR, 0
    rgb = i
    if rgb == TRANSP_COLOUR:
        rgb = TRANSP_DODGE      # see the header: the loader would do this anyway
    return rgb, ((rgb >> 1) | rgb) & 1


def pal_bytes():
    out = bytearray()
    for i in range(256):
        first, second = entry(i)
        if i != TRANSPARENT:
            assert first != TRANSP_COLOUR, (
                "entry %d encodes to $%02X - l2_palette_load would rewrite it "
                "and the file would no longer describe what is displayed" % (i, first))
        out.append(first)
        out.append(second)
    assert len(out) == 512
    return bytes(out)


def build():
    px = [[0] * WIDTH for _ in range(HEIGHT)]
    for r in range(GRID):
        for c in range(GRID):
            idx = r * GRID + c
            y0 = r * SWATCH_H
            x0 = c * SWATCH_W
            for y in range(y0, y0 + SWATCH_H):
                for x in range(x0, x0 + SWATCH_W):
                    px[y][x] = idx

    flat = bytearray()
    for row in px:
        flat.extend(row)
    assert len(flat) == WIDTH * HEIGHT

    # Every index appears, each in exactly one swatch of its own. This is
    # what makes the card a key rather than a picture: a missing or
    # duplicated index would break the read-off against the text.
    counts = [0] * 256
    for b in flat:
        counts[b] += 1
    for i in range(256):
        assert counts[i] == SWATCH_W * SWATCH_H, (
            "index %d covers %d pixels, expected %d - the grid is not one "
            "swatch per index" % (i, counts[i], SWATCH_W * SWATCH_H))

    # 255 IS expected here, unlike tests\art\mkl2card.py where its presence
    # would mean damage. See the header: it is the reserved transparent
    # entry and its swatch is deliberately a hole onto the text layer.
    assert counts[TRANSPARENT] == SWATCH_W * SWATCH_H
    return bytes(flat)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, "palcard.nx2")
    data = pal_bytes() + build()
    assert (len(data) - 512) % WIDTH == 0
    assert (len(data) - 512) // WIDTH == HEIGHT
    with open(path, "wb") as f:
        f.write(data)
    print("wrote %s: %d bytes, %dx%d, %d swatches of %dx%d, index 255 transparent"
          % (path, len(data), WIDTH, HEIGHT, GRID * GRID, SWATCH_W, SWATCH_H))


if __name__ == "__main__":
    main()
