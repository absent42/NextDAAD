# Transparent-paper / layer-order instrument - the FULL-FRAME card for
# tests\tmover.dsf. That fixture's own header block names every band on
# screen and says what a failure of each one means.
#
# Produces tests\out\tmover.nxi, which tests\build-tests.ps1 -TmOver
# stages as sd\TMOVER\001.NXI - the ONE picture that fixture loads with
# PICTURE 1 and shows with DISPLAY 0.
#
# THIS CARD IS THE OPPOSITE OF tests\art\mkl2holes.py IN ONE RESPECT AND
# THE SAME IN ANOTHER. Like mkl2card.py it contains NO pixel at index 255,
# so it punches NO hole anywhere: that is the entire point of the fixture.
# Text over a picture used to require a hole cut in the artwork; the
# feature under test puts the TEXT LAYER on top instead and lets tilemap
# paper decide what shows, so the card it is read against must be a plain
# full-frame illustration with nothing cut out of it. Any transparency
# seen inside this card's footprint is therefore damage, exactly as it is
# on mkl2card.py's card, and any part of the fixture's text that shows
# while the picture is on top is a layer-order fault rather than an
# artwork feature.
#
# ------------------------------------------------------------------
# THE CONSTANTS THIS CARD IS BUILT ON - all verified in source
# ------------------------------------------------------------------
#   L2_TRANSP_INDEX = 255   (src\nextdaad.inc) - the pixel value the
#     loader reserves. l2_pal9_stamp rewrites entry 255 to the transparent
#     colour after EVERY palette load, so index 255 is transparent no
#     matter what this file says its colour is. NO PIXEL HERE USES IT and
#     the build asserts that from the staging side as well.
#   L2_TRANSP_COLOUR = $E3  (src\nextdaad.inc) - a COLOUR compare in
#     NR $14 against the top 8 bits of the 9-bit palette output, for
#     Layer 2 AND for tilemap text mode alike. No palette entry in this
#     card packs to $E3, asserted below, so the loader's $E7 dodge never
#     fires here and every colour in the file is the colour displayed.
#
# ------------------------------------------------------------------
# GEOMETRY - 256x192 IS THE WHOLE SCREEN, AND WHERE THE TEXT LANDS
# ------------------------------------------------------------------
# 256 wide as .NXI (gfxExtTab routes NXI to mode 0 / width 256; the
# file's own bytes carry no width, the EXTENSION decides), 192 rows
# because gfx_derive_height derives the count from the file length as
# (size - 512) / 256 and rejects anything outside 1..192 in mode 0.
#
# A 256x192 Layer 2 surface is inset 32 pixels on both axes from the
# tilemap origin (dev guide chapter-next-tilemap.tex:18, chapter-next-
# layer2.tex:308), so
#
#     tilemap column = L2 x // 4 + 8        (a cell is 4 L2 px wide)
#     tilemap row    = L2 y // 8 + 4        (a cell is 8 L2 px tall)
#
# and this card covers tilemap COLUMNS 8..71 and ROWS 4..27 exactly.
# Rows 0..3 and 28..31, columns 0..7 and 72..79, are outside it: the
# fixture puts its status line and its prompt there so both stay
# readable in BOTH layer orders.
#
# THE FOUR TEXT BANDS the fixture prints are 2 tilemap rows tall, 32
# columns wide, at column 20 - tilemap rows 9-10, 13-14, 17-18 and
# 21-22. In L2 pixels that is x 48..175 and y 40..55, 72..87, 104..119,
# 136..151. Everything below is placed around those four rectangles, so
# each band has something under it that is worth seeing through:
#
#   BAND A (PAPER 227, transparent) lands on the quadrant seam at
#     x = 128, where the picture changes colour from blue to orange. A
#     transparent band shows that seam and the diagonal stripes running
#     under it; an opaque one shows a flat rectangle. Nothing subtle.
#   BAND B (ordinary opaque paper) lands over a black plate carrying the
#     word HIDDEN in white, drawn entirely inside the band's own
#     footprint. With the text on top that word must be COVERED. It is
#     the positive control for "opaque paper really is opaque": a band
#     that has gone transparent by accident reads out its own failure.
#   BAND C (INK 227, transparent glyphs) lands over a vertical rainbow
#     of 8-pixel stripes. The glyph shapes then show a MULTI-COLOURED
#     picture through them rather than one flat colour, so "the letters
#     are cut out of the paper" cannot be confused with "the letters are
#     printed in some colour".
#   BAND D (PAPER 11) lands on plain quadrant field. Nothing is needed
#     under it: the test is that the band renders bright magenta and not
#     a hole, and a hole would show the field it is sitting on.
#
# ------------------------------------------------------------------
# WHY THE FIELD LOOKS THE WAY IT DOES
# ------------------------------------------------------------------
# FOUR COLOURED QUADRANTS, each with its own hue and its own two-letter
# label (NW NE SW SE) in the margin columns the bands do not reach, so a
# single screenshot answers "is the picture up, and is it the right way
# round" before any transparency question is asked. The labels sit at
# x 6..39 and x 214..247, outside the bands' x 48..175, so they stay
# visible in both layer orders.
#
# DIAGONAL STRIPES in a lighter shade of each quadrant's own hue. A flat
# field cannot be told from "Layer 2 is not being displayed at all" by
# eye - the ambiguity that wasted the 2026-08-03 sfxdi run - and a
# stripe pattern showing through a transparent band is unmistakably a
# picture rather than a colour.
#
# A 2px WHITE FRAME and a 2px WHITE CROSS on the quadrant seams. The
# card's extent and its centre are then unambiguous, so a displaced or
# clipped blit reads out as a frame edge that is not at the edge.
#
# THE CAPTION PLATE, black with TMOVER in white, rows 4..7 of the
# tilemap - above every band and above the seam. Confirms at a glance
# that Layer 2 is live and that THIS card is the one staged, before any
# band is judged.
#
# Generated, not committed - a byte-exact function of the constants
# below, the same rule tests\art\mkl2holes.py and mkpalcard.py follow.

import os
import sys

WIDTH = 256
HEIGHT = 192          # gfx_derive_height's hard ceiling for mode 0

# ---- palette -------------------------------------------------------
# RGB333 per entry. byte 0 = RRRGGGBB, byte 1 = blue LSB in bit 0 (the
# Layer 2 colour-priority bit, bit 7, stays clear). No entry may pack to
# $E3 - asserted in pal_bytes below - so nothing here is rewritten by
# l2_palette_load's dodge and the file describes what is displayed.
COLOURS = {
    0:  (0, 0, 0),      # BLACK    - caption plate, HIDDEN plate, labels
    1:  (0, 0, 5),      # BLUE     - quadrant NW
    2:  (7, 3, 0),      # ORANGE   - quadrant NE
    3:  (0, 5, 0),      # GREEN    - quadrant SW
    4:  (5, 0, 6),      # VIOLET   - quadrant SE
    5:  (2, 2, 7),      # BLUE_L   - NW stripes
    6:  (7, 5, 2),      # ORANGE_L - NE stripes
    7:  (2, 7, 2),      # GREEN_L  - SW stripes
    8:  (7, 2, 7),      # VIOLET_L - SE stripes
    9:  (7, 7, 7),      # WHITE    - frame, cross, captions
    10: (7, 7, 0),      # YELLOW   - rainbow
    11: (0, 7, 7),      # CYAN     - rainbow
    12: (7, 0, 0),      # RED      - rainbow
    13: (7, 1, 7),      # MAGSAFE  - rainbow (packs to $E7, never $E3)
    14: (3, 3, 3),      # GREY     - rainbow
    15: (1, 1, 1),      # DKGREY   - caption plate border
    255: (0, 7, 0),     # GREEN    - the stamp-failure signature: entry
                        #   255 is overwritten with the transparent
                        #   colour by l2_pal9_stamp on every load, and no
                        #   pixel here uses index 255, so this colour can
                        #   only appear on screen if something is badly
                        #   wrong. Green is used nowhere else on the card.
}

BLACK, BLUE, ORANGE, GREEN, VIOLET = 0, 1, 2, 3, 4
BLUE_L, ORANGE_L, GREEN_L, VIOLET_L = 5, 6, 7, 8
WHITE, YELLOW, CYAN, RED, MAGSAFE, GREY, DKGREY = 9, 10, 11, 12, 13, 14, 15
TRANSP = 255

TRANSP_COLOUR = 0xE3          # L2_TRANSP_COLOUR

# quadrant: (base, stripe, x0, y0, x1, y1, label, label colour)
QUADS = [
    (BLUE,   BLUE_L,   0,   0,   127, 95,  "NW", WHITE),
    (ORANGE, ORANGE_L, 128, 0,   255, 95,  "NE", BLACK),
    (GREEN,  GREEN_L,  0,   96,  127, 191, "SW", BLACK),
    (VIOLET, VIOLET_L, 128, 96,  255, 191, "SE", WHITE),
]

# Label boxes, chosen to miss the bands' x 48..175 entirely.
LABEL_X = {"NW": 6, "SW": 6, "NE": 214, "SE": 214}
LABEL_Y = {"NW": 52, "NE": 52, "SW": 120, "SE": 120}
LABEL_SCALE = 3

CAPTION = "TMOVER"
CAPTION_SCALE = 3
CAPTION_TOP = 8               # plate rows 6..32, inside tilemap rows 4..7

# The four text bands, in L2 pixel coordinates, derived from the tilemap
# rectangles the fixture prints into (WINAT row 20 / WINSIZE 2 32).
BAND_X0, BAND_X1 = 48, 175
BANDS = {
    "A": (40, 55),
    "B": (72, 87),
    "C": (104, 119),
    "D": (136, 151),
}

# Band B's positive control: a black plate carrying HIDDEN, drawn wholly
# inside band B's own rectangle so an opaque band covers all of it.
HIDDEN_TEXT = "HIDDEN"
HIDDEN_SCALE = 2
HIDDEN_PLATE = (60, 72, 168, 87)      # x0, y0, x1, y1 - band B exactly

# Band C's positive control: vertical rainbow stripes, wider than the
# band so the stripes are visibly continuous past its ends.
RAINBOW = [RED, ORANGE, YELLOW, GREEN, CYAN, BLUE_L, VIOLET, MAGSAFE, WHITE, GREY]
RAINBOW_BOX = (40, 100, 183, 123)     # x0, y0, x1, y1
RAINBOW_STEP = 8

STRIPE_PERIOD = 16            # diagonal stripe pitch, in pixels
STRIPE_WIDTH = 4


def pack0(rgb):
    r, g, b = rgb
    return (r << 5) | (g << 2) | (b >> 1)


def pal_bytes():
    out = bytearray()
    collide = []
    for i in range(256):
        r, g, b = COLOURS.get(i, (0, 0, 0))
        first = pack0((r, g, b))
        if first == TRANSP_COLOUR:
            collide.append(i)
        out.append(first)
        out.append(b & 1)
    # No entry may pack to the transparent colour. On this card that is
    # not a dodge test (mkl2holes.py owns that one) - it is the guarantee
    # that every colour in the file is the colour displayed, so a band
    # that shows through can only be the tilemap and never the palette.
    assert collide == [], (
        "entries %r pack to $%02X - l2_palette_load would rewrite them and "
        "this file would stop describing what is displayed" % (collide, TRANSP_COLOUR))
    assert len(out) == 512
    return bytes(out)


# ---- 5x7 stroke font, scaled -----------------------------------------
FONT = {
    'T': ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    'M': ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    'O': ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    'V': ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    'E': ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    'R': ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    'N': ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    'W': ["10001", "10001", "10001", "10101", "10101", "11011", "10001"],
    'S': ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    'H': ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    'I': ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    'D': ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    ' ': ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
}

GAP = 3


def text_size(text, scale):
    gw, gh = 5 * scale, 7 * scale
    return len(text) * (gw + GAP) - GAP, gh


def draw_text(px, text, left, top, colour, scale):
    gw = 5 * scale
    x = left
    for ch in text:
        glyph = FONT[ch]
        for gy in range(7):
            for gx in range(5):
                if glyph[gy][gx] != '1':
                    continue
                for sy in range(scale):
                    for sx in range(scale):
                        px[top + gy * scale + sy][x + gx * scale + sx] = colour
        x += gw + GAP


def fill(px, y0, y1, x0, x1, idx):
    for y in range(y0, y1 + 1):
        row = px[y]
        for x in range(x0, x1 + 1):
            row[x] = idx


def build():
    px = [[BLACK] * WIDTH for _ in range(HEIGHT)]

    # 1. the four quadrants, each with diagonal stripes in its own
    #    lighter shade - the "this is a picture, not a flat colour"
    #    readout that every transparent band is judged against
    for base, stripe, x0, y0, x1, y1, _, _ in QUADS:
        for y in range(y0, y1 + 1):
            row = px[y]
            for x in range(x0, x1 + 1):
                row[x] = stripe if ((x + y) % STRIPE_PERIOD) < STRIPE_WIDTH else base

    # 2. band C's rainbow, drawn before the frame so the frame wins
    rx0, ry0, rx1, ry1 = RAINBOW_BOX
    for x in range(rx0, rx1 + 1):
        colour = RAINBOW[((x - rx0) // RAINBOW_STEP) % len(RAINBOW)]
        for y in range(ry0, ry1 + 1):
            px[y][x] = colour

    # 3. band B's HIDDEN plate, wholly inside band B's own rectangle
    hx0, hy0, hx1, hy1 = HIDDEN_PLATE
    fill(px, hy0, hy1, hx0, hx1, BLACK)
    hw, hh = text_size(HIDDEN_TEXT, HIDDEN_SCALE)
    draw_text(px, HIDDEN_TEXT, hx0 + (hx1 - hx0 + 1 - hw) // 2,
              hy0 + (hy1 - hy0 + 1 - hh) // 2, WHITE, HIDDEN_SCALE)

    # 4. the quadrant labels, in the margin columns no band reaches
    for _, _, _, _, _, _, label, colour in QUADS:
        draw_text(px, label, LABEL_X[label], LABEL_Y[label], colour, LABEL_SCALE)

    # 5. the caption plate
    cw, ch = text_size(CAPTION, CAPTION_SCALE)
    cx = (WIDTH - cw) // 2
    fill(px, CAPTION_TOP - 3, CAPTION_TOP + ch + 2, cx - 6, cx + cw + 5, BLACK)
    fill(px, CAPTION_TOP - 3, CAPTION_TOP - 3, cx - 6, cx + cw + 5, DKGREY)
    fill(px, CAPTION_TOP + ch + 2, CAPTION_TOP + ch + 2, cx - 6, cx + cw + 5, DKGREY)
    draw_text(px, CAPTION, cx, CAPTION_TOP, WHITE, CAPTION_SCALE)

    # 6. the quadrant seams and the frame, last, so they cut everything
    fill(px, 0, HEIGHT - 1, 126, 127, WHITE)
    fill(px, 94, 95, 0, WIDTH - 1, WHITE)
    fill(px, 0, 1, 0, WIDTH - 1, WHITE)
    fill(px, HEIGHT - 2, HEIGHT - 1, 0, WIDTH - 1, WHITE)
    fill(px, 0, HEIGHT - 1, 0, 1, WHITE)
    fill(px, 0, HEIGHT - 1, WIDTH - 2, WIDTH - 1, WHITE)

    flat = bytearray()
    for row in px:
        flat.extend(row)
    assert len(flat) == WIDTH * HEIGHT

    # THE ONE ASSERTION THIS CARD RESTS ON: no transparent pixel. A hole
    # anywhere would let text show while the PICTURE is on top, which is
    # exactly the reading the fixture uses to fail the layer order.
    assert TRANSP not in set(flat), "index 255 (transparent) appears in the card"
    used = set(flat)
    missing = set(COLOURS) - used - {TRANSP}
    assert not missing, "indices given a colour but never drawn: %r" % sorted(missing)
    extra = used - set(COLOURS)
    assert not extra, "indices drawn but given no colour: %r" % sorted(extra)
    return bytes(flat)


def band_report():
    """What sits under each band, recomputed from the constants above."""
    lines = []
    for tag in sorted(BANDS):
        y0, y1 = BANDS[tag]
        row0, row1 = y0 // 8 + 4, y1 // 8 + 4
        col0, col1 = BAND_X0 // 4 + 8, BAND_X1 // 4 + 8
        lines.append("  band %s  L2 x %d-%d y %d-%d  = tilemap rows %d-%d cols %d-%d"
                     % (tag, BAND_X0, BAND_X1, y0, y1, row0, row1, col0, col1))
    return lines


def decode_back(path):
    """Read the written file back and prove it from its own bytes."""
    data = open(path, "rb").read()
    print("decode-back of %s" % path)
    print("  %d bytes = 512 palette + %d pixels" % (len(data), len(data) - 512))
    assert (len(data) - 512) % WIDTH == 0, "not a whole number of 256-byte rows"
    rows = (len(data) - 512) // WIDTH
    print("  gfx_derive_height would derive %d rows (limit 1..192)" % rows)
    assert rows == HEIGHT

    pal, pix = data[:512], data[512:]
    e3 = [i for i in range(256) if pal[2 * i] == TRANSP_COLOUR]
    print("  palette entries packing to $%02X: %r (must be empty - no dodge fires here)"
          % (TRANSP_COLOUR, e3))
    assert e3 == []
    print("  entry 255 authored RGB333 %s, byte0 $%02X - overwritten with $%02X by "
          "l2_pal9_stamp; visible only if that stamp fails"
          % (COLOURS[TRANSP], pal[510], TRANSP_COLOUR))

    counts = {}
    for v in pix:
        counts[v] = counts.get(v, 0) + 1
    print("  indices used: %r" % sorted(counts))
    assert TRANSP not in counts, "the card punches a hole - it must not"
    print("  index 255 pixels: 0 (the card is opaque everywhere)")
    for line in band_report():
        print(line)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, "tmover.nxi")
    data = pal_bytes() + build()
    assert (len(data) - 512) // WIDTH == HEIGHT
    with open(path, "wb") as f:
        f.write(data)
    print("wrote %s: %d bytes, %dx%d, 4 quadrants, 0 transparent pixels"
          % (path, len(data), WIDTH, HEIGHT))
    decode_back(path)


if __name__ == "__main__":
    main()
