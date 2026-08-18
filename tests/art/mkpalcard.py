# Full-colour Layer 2 reference card for the 256-colour text fixture
# (tests\palette.dsf).
#
# Produces tests\out\palcard.nx2, which tests\build-tests.ps1 -Palette
# stages as sd\PALETTE\001.NX2 - the one picture the fixture loads with
# PICTURE 1 and draws with DISPLAY 0.
#
# WHAT THIS CARD IS FOR. The fixture exercises text ink and paper across
# the full 0-255 range. This card puts the SAME 256 colours on Layer 2,
# directly above the text, so the two can be read against each other in
# one glance: it answers "does INK 200 actually give colour 200" without
# anyone counting bits, and it puts Layer 2 and the tilemap on screen
# together so any interference between them shows up.
#
# IT IS A KEY, NOT DECORATION. Swatch n is palette index n, laid out as
# a 16 x 16 grid in index order - swatch (row r, column c) is index
# r * 16 + c. The palette is the IDENTITY palette: entry i encodes
# RRRGGGBB = i, with the ninth blue bit derived as B1 OR B0. That is
# exactly what pal_colour (src\tmpairs.asm) computes for a text colour
# 16-255, and exactly what the core derives on an 8-bit palette write
# (zxnext.vhd:5425). So swatch n IS the colour INK n produces, and a
# mismatch between a swatch and the text below it is a real defect
# rather than a judgement call.
#
# TWO SWATCHES ARE DELIBERATELY NOT THE IDENTITY COLOUR, and both are
# consequences of Layer 2 transparency rather than faults:
#
#   INDEX 255 IS TRANSPARENT. l2_palette_load reserves 255 as the sole
#     transparent entry after any picture load (see its header,
#     overlay2.asm), so the bottom-right swatch is a hole: whatever the
#     tilemap holds behind the card shows through it. That is the one
#     swatch that must NOT match INK 255 - text ink 255 is white, this
#     swatch is a window. It is included rather than skipped because a
#     card that quietly omitted it would hide the reserved index from
#     the person reading the card.
#
#     READING THAT HOLE NEEDS SOMETHING BEHIND IT. The fixture clears the
#     card's exact footprint to a saturated red before drawing, so the
#     hole shows red and a failure shows black. Against a bare tilemap
#     the hole reveals the default black paper, and a working hole and a
#     broken one look identical - which is why the backdrop is part of
#     the instrument, not decoration.
#
#   INDEX 227 IS $E7, NOT $E3. l2_palette_load rewrites any entry whose
#     first byte is $E3 to $E7 (one green step up), because $E3 is the
#     transparency colour and a second entry carrying it would punch
#     unintended holes. 227 encodes to $E3 under the identity rule, so
#     it is written as $E7 here - the file then matches what the
#     hardware displays instead of describing a value the loader would
#     silently change underneath it. Swatches 227 and 231 therefore
#     show the SAME colour (231 is $E7 by identity) - the dodge landing
#     on its escape, not a defect.
#     Text INK 227 is unaffected and stays $E3: the tilemap's palette is
#     not the one l2_palette_load rewrites.
#
# SIZE AND PLACEMENT. 320 x 128 as .NX2. A 320-wide picture covers
# exactly the same area of screen as the 80x32 text grid, so one
# character cell is 4 picture pixels wide and 8 tall with no inset
# (manual\graphics.md). The card therefore occupies tilemap rows 0 to 15
# across all 80 columns, and art is top-aligned with the screen below it
# left transparent, so it needs no padding to leave the text room - the
# fixture puts its text window at row 16. Height is derived by
# gfx_derive_height from the file length as (bytes - 512) / 320, so the
# size is the one thing that has to be right for the card to load at
# all; 320-wide art may be 1 to 256 rows.
#
# .NX2 ALSO CHANGES THE BLIT PATH, which is worth knowing when reading a
# fault. gfx_blit routes 320-wide art to gfx_row_scatter320, a CPU
# column scatter, where 256-wide .NXI art goes to gfx_row_copy256 and
# one DMA call per row. So this card exercises the scatter path, and
# damage that is specific to it shows up here rather than on the .NXI
# cards elsewhere in the suite.
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
