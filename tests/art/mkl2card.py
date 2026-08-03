# Layer 2 corruption-detector card generator for the sampled-SFX
# DI-exposure fixture (tests\sfxdi.dsf, run sheet
# .superpowers\sdd\sfx-di-audible-test.md).
#
# Produces tests\out\l2card.nxi, which tests\build-tests.ps1 -SfxDi
# stages as sd\SFXDI\001.NXI - the ONE picture the fixture loads with
# PICTURE 1 and then blits, over and over, with DISPLAY 0.
#
# WHY A GENERATED CARD AND NOT CORPUS ART. The fixture's visual job is
# to answer "did dma_copy move every byte to the right place", and the
# image IS the instrument. Real location art is the worst possible
# instrument for that: it is high-detail, so a few wrong bytes hide in
# the texture, and its adaptive palette can legitimately use index 254
# - which l2_palette_load stamps TRANSPARENT - so a correct blit can
# show holes and a hole means nothing. Every property below exists to
# make a specific class of damage impossible to miss and impossible to
# fake.
#
#   NO PIXEL IS EVER INDEX 254. Only indices 0..15 are used, and every
#     palette entry from 16 up is black. l2_palette_load reserves 254
#     as the sole transparent entry after ANY picture load (see its own
#     header, overlay2.asm), so with 254 unused ANY transparency inside
#     the card's area is damage, full stop - either a byte the copy
#     failed to write (the back surface is pre-cleared to $FE by
#     l2_clear_back) or a byte it wrote from the wrong place. That is
#     what makes the tilemap backdrop under the card a binary detector:
#     the fixture prints a solid red block behind the picture, and red
#     showing through is not a judgement call.
#   FLAT FIELDS. The eight colour bands and the white block are single-
#     valued over large areas, so ONE wrong byte is a visible speck of a
#     colour that does not belong there. Detail art cannot do this.
#   A 16-STEP RAMP. A horizontal shift of the copy shows as a break in
#     a monotonic colour sequence - visible even when the displaced
#     bytes are themselves legal picture bytes.
#   A 2x2 CHECKERBOARD. A displacement by an ODD number of bytes
#     inverts the checkerboard phase; the boundary between shifted and
#     unshifted regions reads as a hard seam.
#   A CAPTION. Confirms at a glance that Layer 2 really is displaying
#     and that the staged asset is this one - the exact thing the
#     2026-08-03 run could not confirm ("LAYER 2 NOT ACTIVE DURING
#     TEST"). Its thin strokes are also the finest structure on the
#     card, so they take the smallest damage first.
#
# GEOMETRY. 256 wide, 128 rows.
#   256 WIDE IS MANDATORY, not cosmetic. gfx_blit routes 256-wide art
#     to gfx_row_copy256, which calls dma_copy once per row; 320-wide
#     art goes to gfx_row_scatter320, a CPU column scatter with no DMA
#     branch at all (see its header). A 320-wide card would exercise
#     nothing. The .NXI extension is what selects mode 0 / width 256 in
#     gfxExtTab - the file's own bytes carry no width.
#   128 ROWS puts the card on tilemap rows 4..19 and leaves rows 20..31
#     for the fixture's text window. Layer 2 in 256x192 mode is inset 32
#     pixels from the tilemap origin on both axes (dev guide
#     chapter-next-tilemap.tex:18 "Tilemap layer overlaps ULA by 32
#     pixels on each side", chapter-next-layer2.tex:308), so L2 row r
#     lands on tilemap row r/8 + 4 and L2 column c on tilemap column
#     c/4 + 8. 128 rows is also 128 dma_copy calls per DISPLAY 0.
#
# FILE FORMAT (Gfx2Next .nxi, as the interpreter consumes it): 512-byte
# palette FIRST - 256 entries x 2 bytes, byte 0 = RRRGGGBB, byte 1 bit 0
# = the blue LSB, bit 7 = L2 priority - then width*height 8-bit palette
# indices, row-major. gfx_blit skips the leading 512 for the pixel
# stream and rewinds to offset 0 for l2_palette_load format 1; height
# is DERIVED by gfx_derive_height as (filesize - 512) / 256, so the row
# count is carried by the file length alone and 128 must divide exactly.
#
# Written by hand rather than through tools\png2nx.py (PNG + gfx2next
# -pal-embed, the canonical route for real art) because that route's
# ADAPTIVE 256 palette is exactly the property this card must not have:
# it chooses its own indices and can land on 254.

import os
import struct
import sys

WIDTH = 256
HEIGHT = 128

# --- palette ------------------------------------------------------
# 16 used entries, 3 bits per channel. None of these encode to $FE
# (which would be r=7 g=7 b=4or5): l2_palette_load rewrites any entry
# whose first byte is $FE to $FF to stop it punching an unintended
# hole, and an entry silently rewritten under us would be one more
# thing the card could not vouch for.
COLOURS = [
    (0, 0, 0),      # 0  black      - borders and rules
    (7, 7, 7),      # 1  white
    (7, 0, 0),      # 2  red
    (0, 7, 0),      # 3  green
    (0, 0, 7),      # 4  blue
    (7, 7, 0),      # 5  yellow
    (7, 0, 7),      # 6  magenta
    (0, 7, 7),      # 7  cyan
    (7, 3, 0),      # 8  orange
    (3, 3, 3),      # 9  grey
    (4, 7, 0),      # 10 lime
    (7, 4, 6),      # 11 pink
    (4, 0, 7),      # 12 purple
    (0, 5, 4),      # 13 teal
    (4, 2, 0),      # 14 brown
    (3, 5, 7),      # 15 sky
]

BLACK, WHITE, RED, GREEN, BLUE, YELLOW, MAGENTA, CYAN = range(8)
ORANGE, GREY, LIME, PINK, PURPLE, TEAL, BROWN, SKY = range(8, 16)

BANDS = [RED, ORANGE, YELLOW, LIME, GREEN, CYAN, BLUE, MAGENTA]
RAMP = [BLACK, GREY, BROWN, RED, ORANGE, YELLOW, LIME, GREEN,
        TEAL, CYAN, SKY, BLUE, PURPLE, MAGENTA, PINK, WHITE]


def pal_bytes():
    out = bytearray()
    for i in range(256):
        if i < len(COLOURS):
            r, g, b = COLOURS[i]
        else:
            r = g = b = 0
        first = (r << 5) | (g << 2) | (b >> 1)
        assert first != 0xFE, "entry %d encodes to $FE - l2_palette_load would rewrite it" % i
        out.append(first)
        out.append(b & 1)
    return bytes(out)


# --- 5x7 font, only the glyphs the caption needs ------------------
FONT = {
    ' ': ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
    'A': ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    'D': ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    'E': ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    'L': ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    'M': ["10001", "11011", "10101", "10001", "10001", "10001", "10001"],
    'S': ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    'T': ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    '2': ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
}

CAPTION = "L2 DMA TEST"
SCALE = 3
GLYPH_W = 5 * SCALE
GLYPH_H = 7 * SCALE
GAP = 3


def blank():
    return [[BLACK] * WIDTH for _ in range(HEIGHT)]


def fill(px, y0, y1, x0, x1, idx):
    for y in range(y0, y1 + 1):
        row = px[y]
        for x in range(x0, x1 + 1):
            row[x] = idx


def draw_caption(px, top, colour):
    total = len(CAPTION) * (GLYPH_W + GAP) - GAP
    x0 = (WIDTH - total) // 2
    for ch in CAPTION:
        glyph = FONT[ch]
        for gy in range(7):
            for gx in range(5):
                if glyph[gy][gx] != '1':
                    continue
                for sy in range(SCALE):
                    for sx in range(SCALE):
                        px[top + gy * SCALE + sy][x0 + gx * SCALE + sx] = colour
        x0 += GLYPH_W + GAP


def build():
    px = blank()

    # caption block, rows 3..23
    draw_caption(px, 3, WHITE)

    # eight flat colour bands, rows 28..59 - the speck detector
    for i, c in enumerate(BANDS):
        fill(px, 28, 59, i * 32, i * 32 + 31, c)

    # 16-step ramp, rows 62..85 - the horizontal-shift detector
    for i, c in enumerate(RAMP):
        fill(px, 62, 85, i * 16, i * 16 + 15, c)

    # 2x2 checkerboard, rows 88..105 - the odd-shift phase detector
    for y in range(88, 106):
        for x in range(WIDTH):
            px[y][x] = WHITE if ((x >> 1) + (y >> 1)) & 1 else BLUE

    # solid white, rows 108..125 - the purest speck detector: any pixel
    # here that is not white is damage, no comparison needed
    fill(px, 108, 125, 0, WIDTH - 1, WHITE)

    # 2px black frame, so the card's extent (and any bleed past it) is
    # unambiguous
    fill(px, 0, 1, 0, WIDTH - 1, BLACK)
    fill(px, HEIGHT - 2, HEIGHT - 1, 0, WIDTH - 1, BLACK)
    for y in range(HEIGHT):
        px[y][0] = px[y][1] = BLACK
        px[y][WIDTH - 2] = px[y][WIDTH - 1] = BLACK

    flat = bytearray()
    for row in px:
        flat.extend(row)
    assert len(flat) == WIDTH * HEIGHT
    assert max(flat) < len(COLOURS), "a pixel used an index with no colour"
    assert 254 not in flat, "index 254 is reserved transparent - see the header"
    return bytes(flat)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(outdir, exist_ok=True)
    data = pal_bytes() + build()
    assert (len(data) - 512) % WIDTH == 0
    assert (len(data) - 512) // WIDTH == HEIGHT
    path = os.path.join(outdir, "l2card.nxi")
    with open(path, "wb") as f:
        f.write(data)
    print("wrote %s  %d bytes  %dx%d  %d colours used"
          % (path, len(data), WIDTH, HEIGHT, len(COLOURS)))


if __name__ == "__main__":
    main()
