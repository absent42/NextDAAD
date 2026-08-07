# Layer 2 TRANSPARENCY instrument - punch-out card generator for the
# hole/hardware fixture (tests\l2holes.dsf, run sheet
# docs\superpowers\l2-holes-run-sheet.md).
#
# Produces tests\out\l2holes.nxi, which tests\stage-l2holes.ps1 stages as
# sd\L2HOLES\001.NXI - the ONE picture the fixture loads with PICTURE 1
# and shows with DISPLAY 0, over a tilemap filled edge to edge with
# position-identifying text.
#
# THIS CARD IS THE EXACT INVERSE OF tests\art\mkl2card.py. That one is a
# corruption detector and deliberately contains NO pixel of index 255, so
# ANY transparency inside it is damage. This one is a transparency
# detector and deliberately punches thirteen holes at index 255, so every
# hole that does NOT show text is damage. Read that card's header first;
# everything below assumes its geometry derivation.
#
# ------------------------------------------------------------------
# THE THREE CONSTANTS THIS CARD IS BUILT ON - all verified in source
# ------------------------------------------------------------------
#   L2_TRANSP_INDEX = 255   (src\nextdaad.inc:266) - the PIXEL value that
#     punches a hole. l2_pal9_stamp (src\overlay2.asm:278) writes entry
#     255 = L2_TRANSP_COLOUR after EVERY palette load, on every path, so
#     255 is the ONLY transparent entry after any picture load.
#   L2_TRANSP_COLOUR = $E3  (src\nextdaad.inc:254) - a COLOUR in NR $14,
#     compared against the TOP 8 BITS of each Layer 2 pixel's 9-bit
#     palette output. Not an index compare.
#   THE DODGE. l2_pal9_run (src\overlay2.asm:293) rewrites the RRRGGGBB
#     byte of ANY palette entry that equals $E3 to $E2 before programming
#     it, so art that happens to contain saturated magenta does not punch
#     unintended holes. l2_palette_load's B=0 loop (:259) does the same
#     with the same -1. Both loops run over all 256 entries; the stamp
#     then re-forces entry 255 back to $E3 AFTERWARDS, so the dodge can
#     never disarm the reserved index.
#
# Layer 2 sits ABOVE the tilemap - l2_enable writes NR $15 = %000 "S L U"
# (src\overlay2.asm:123) - so a hole in Layer 2 reveals tilemap text
# beneath it. That is the whole instrument: holes are windows onto text.
#
# ------------------------------------------------------------------
# GEOMETRY, AND WHY 256x192 IS THE WHOLE SCREEN
# ------------------------------------------------------------------
# 256 WIDE IS MANDATORY. gfxExtTab routes .NXI to mode 0 / width 256 and
# gfx_blit sends 256-wide art to gfx_row_copy256 -> dma_copy; .NX2 (320
# wide) goes to gfx_row_scatter320, a CPU column scatter. The file's own
# bytes carry no width - the EXTENSION decides. A card staged as .NX2
# would exercise a different blitter.
#
# 192 ROWS IS THE MAXIMUM, not a choice. gfx_derive_height
# (src\overlay2.asm:1459) derives the row count from the file length as
# (size - 512) / width and, for mode 0, fails any count outside 1..192
# ("cp 193 / jr nc, .bad"). 192 rows is therefore the full-screen card the
# task asks for, and 512 + 256*192 = 49664 bytes must divide exactly.
#
# THE TILEMAP MAPPING. The tilemap is 80x32 cells of 8x8 pixels = 640x256
# tilemap pixels, and it "overlaps ULA by 32 pixels on each side"
# (docs\zx-next-dev-guide-2022-07-15\chapter-next-tilemap.tex:18); Layer 2
# 320x256 is "the regular 256x192 mode with additional 32 pixel border
# around (32 + 256 + 32 = 320 and 32 + 192 + 32 = 256)"
# (chapter-next-layer2.tex:308). So both layers cover the same physical
# screen, the tilemap at twice the horizontal pixel density, and a
# 256x192 Layer 2 surface is inset 32 pixels on both axes:
#
#     tilemap column = L2 x // 4 + 8        (a cell is 4 L2 px wide)
#     tilemap row    = L2 y // 8 + 4        (a cell is 8 L2 px tall)
#
# A full-screen 256x192 card therefore covers tilemap COLUMNS 8..71 and
# ROWS 4..27 exactly. Columns 0..7 and 72..79, rows 0..3 and 28..31 are
# OUTSIDE it - that margin is the fixture's control area, and text there
# must stay visible whatever Layer 2 does.
#
# ------------------------------------------------------------------
# WHY EACH PIECE OF THE OPAQUE FIELD IS THERE
# ------------------------------------------------------------------
# THE FIELD IS NOT FLAT AND NOT BLACK. A flat black field cannot be told
# apart from "Layer 2 is not being displayed at all" by eye, and that
# exact ambiguity is what wasted the 2026-08-03 sfxdi run ("LAYER 2 NOT
# ACTIVE DURING TEST"). Every opaque pixel here belongs to a structure
# whose absence or displacement is visible on its own:
#
#   32x32 CHECKERBOARD, brown and dark red, with a 1px orange line on
#     every 32-pixel boundary. 32 L2 px is exactly 8 tilemap columns and
#     4 tilemap rows, so the block grid IS a tilemap-cell ruler: the grid
#     lines land on cell boundaries and nowhere else. A blit displaced by
#     any amount that is not a multiple of 32 puts the grid lines off the
#     cell boundaries, which reads against the text showing through the
#     holes.
#   A 2px WHITE FRAME on all four edges. The card's extent is then
#     unambiguous, and a vertical displacement shows as a frame edge that
#     is not at the top or bottom of the picture area.
#   AN 8-STEP GREY RAMP, rows 160..175, 32 px per step, aligned to the
#     same 32-px grid and crossed by the same orange grid lines. A
#     horizontal displacement breaks a monotonic sequence AND separates
#     the step boundaries from the grid lines - two independent readouts
#     of the same fault, one of which survives even if the reader cannot
#     remember which grey came first.
#   A 2x2 CHECKERBOARD, rows 176..191 between the bottom corner holes.
#     A displacement by an ODD number of bytes inverts its phase, which
#     reads as a hard seam. This is the only element that detects a
#     one-byte shift.
#   A CAPTION, "L2 HOLES". Confirms at a glance that Layer 2 is live and
#     that THIS card is the one staged, before any hole is judged.
#
# ------------------------------------------------------------------
# THE HOLES, AND WHY EACH ONE IS SHAPED AND PLACED AS IT IS
# ------------------------------------------------------------------
# Every hole is positioned so that the text it exposes NAMES it. The
# fixture fills the tilemap with 8-column units of the form
#
#     rr - cc t t .          e.g. "12-16DG."  = row 12, column 16, tag DG
#
# where columns 8u..8u+7 carry unit u, characters 5 and 6 carry the tag,
# and character 7 is a spacer. A hole that exposes a whole unit therefore
# reads out its own row, its own column and its own name. The tag column
# pair (8u+5, 8u+6) is what a hole must cover for its NAME to appear; the
# table at the foot of this comment is emitted, recomputed, by every run
# of this script, and tests\l2holes.dsf's text is written to match it.
#
#   FOUR CORNER HOLES, 32x16 (TL TR BL BR). 32 px wide is not cosmetic:
#     it is exactly one 8-column text unit, the smallest hole that can
#     expose a whole unit and so name itself. They sit on the extreme
#     corner pixels, which are the first and last bytes of the first and
#     last rows - the bytes an off-by-one row loop or a clipped blit
#     loses first. They also cut the white frame, so a corner that shows
#     frame instead of text is unmistakable.
#   THE CENTRE DISC, radius 24 at (128,96). The centre of the screen, and
#     CURVED: every row of it starts and ends at a different byte offset,
#     so a blitter that handles only whole rows or whole bytes shows a
#     stepped or squared-off edge instead of a circle.
#   THE DIAGONAL TRIANGLE, 48x48 at (32,64), hole where (x-32) <= (y-64).
#     A straight diagonal edge advancing exactly one pixel per row. It
#     tapers to a SINGLE PIXEL at its apex, so the finest possible edge
#     case sits at a known place instead of being hunted for.
#   THE RING, outer radius 23 / inner radius 6 at (200,88). The opaque
#     island in the middle is the point: transparency must be per-pixel,
#     not a flood or a bounding box. An island that vanishes means holes
#     are being filled by area rather than by index.
#   THE SIZE LADDER, squares of 32, 16 and 8 pixels, then a 4x8 hole (one
#     whole tilemap CELL - the smallest hole that can still show a
#     readable character), then 2x2, then 1x1. The 1x1 hole is one byte:
#     it is the single most sensitive element on the card and it either
#     shows a coloured dot or it does not.
#   THREE TARGET PATCHES, sand with a red crosshair, around the 4x8, 2x2
#     and 1x1 holes. A one-byte hole in a 49,152-byte picture cannot be
#     found by scanning; the crosshair says where to look, and the sand
#     patch guarantees the surrounding colour is nothing like the dark
#     blue tilemap paper the hole exposes.
#
# ------------------------------------------------------------------
# THE DODGE TEST - the most valuable single element on this card
# ------------------------------------------------------------------
# Two adjacent solid blocks, tilemap rows 9..11:
#
#   BLOCK "E3", index 14 = RGB333 (7,0,7). Its RRRGGGBB byte packs to
#     $E3 - EQUAL to L2_TRANSP_COLOUR. This is the entry the interpreter
#     must dodge. Correct behaviour: l2_pal9_run rewrites the byte to
#     $E2, the second byte's blue LSB (1) is left alone, so the entry
#     renders as RGB333 (7,0,5) - saturated magenta, two steps of blue
#     down, NOT transparent.
#   BLOCK "E7", index 15 = RGB333 (7,1,7). One step of green off pure
#     magenta packs to $E7, is left alone by both copy loops, and renders
#     exactly as authored. It is the same escape nxv2enc.py's
#     TRANSP_REMAP picks for the same colour.
#
# PASS: both blocks are magenta, E3 very slightly duller/less blue than
# E7, and NEITHER shows text. FAIL: the E3 block shows text - the dodge
# did not happen and any artist whose palette lands on saturated magenta
# gets holes punched through their own picture. That is a real, shipped-
# art failure mode, not a theoretical one: Task 7 of the 2026-08-06
# Layer 2 plan found this collision already present in corpus art.
#
# The blocks are labelled "E3" and "E7" in black, 15x21 glyphs, so the
# verdict does not depend on remembering which block is which. The
# assertion below pins this down from the other end: EXACTLY ONE non-255
# palette entry may pack to $E3, and it must be index 14.
#
# ------------------------------------------------------------------
# TWO COLOURS THAT EXIST ONLY TO BE ABSENT
# ------------------------------------------------------------------
# DARK BLUE. The fixture's text window uses PAPER 1 = dadPalette[1] =
# RGB333 (0,0,6) (src\tilemap.asm:247). NO colour on this card has any
# blue in it except white and the two magentas, and no large flat area is
# blue at all. So blue inside the card's footprint means a hole, and that
# is a judgement anyone can make - including on the 1x1 hole, where no
# glyph is readable and the colour is the entire readout.
#
# BRIGHT GREEN. Palette entry 255 in THIS FILE is RGB333 (0,7,0), a
# colour used nowhere else on the card and deliberately excluded from the
# fixture's text inks. It should never be seen: l2_pal9_stamp overwrites
# entry 255 with $E3 after the copy loop, on every path. If the holes
# come up BRIGHT GREEN instead of showing text, the stamp did not run -
# the file's own entry 255 reached the hardware. That failure has a
# self-naming signature instead of looking like "the holes are the wrong
# colour". (Writing $E3 into entry 255 here would have hidden it: the
# dodge would rewrite it to $E2 and a missing stamp would show opaque
# magenta, indistinguishable from the E3 block failing.)
#
# ------------------------------------------------------------------
# FILE FORMAT (Gfx2Next .nxi, as the interpreter consumes it)
# ------------------------------------------------------------------
# 512-byte palette FIRST - 256 entries x 2 bytes, byte 0 = RRRGGGBB,
# byte 1 bit 0 = the blue LSB and bit 7 = L2 priority - then width*height
# 8-bit palette indices, row-major. gfx_blit skips the leading 512 for
# the pixel stream and rewinds to offset 0 for l2_palette_load format 1.
#
# Written by hand rather than converted from a PNG through gfx2next for
# the same reason mkl2card.py is: that route's ADAPTIVE palette picks its
# own colours, so which index carries which colour - and whether any
# entry lands on $E3 - would not be under this card's control. Here it
# is the entire point.

import os
import sys

WIDTH = 256
HEIGHT = 192          # gfx_derive_height's hard ceiling for mode 0

# --- palette ------------------------------------------------------
# Sixteen used entries plus entry 255. Every colour is warm, neutral or
# magenta: nothing here is blue (the tilemap paper) or green (the
# stamp-failure signature), so both of those read as faults on sight.
COLOURS = {
    0:  (0, 0, 0),      # BLACK   - the "E3"/"E7" labels
    1:  (7, 7, 7),      # WHITE   - frame, caption strokes, ramp top, 2x2
    2:  (1, 1, 1),      # G1      - ramp step 1
    3:  (2, 2, 2),      # G2      - ramp step 2
    4:  (3, 3, 3),      # G3      - ramp step 3
    5:  (4, 4, 4),      # G4      - ramp step 4
    6:  (5, 5, 5),      # G5      - ramp step 5
    7:  (6, 6, 6),      # G6      - ramp step 6
    8:  (4, 2, 0),      # BROWN   - checkerboard block A
    9:  (2, 0, 0),      # DKRED   - checkerboard block B, 2x2 checker
    10: (7, 3, 0),      # ORANGE  - 32px grid lines
    11: (7, 7, 0),      # YELLOW  - the caption
    12: (7, 0, 0),      # RED     - target crosshairs
    13: (6, 5, 2),      # SAND    - target patches
    14: (7, 0, 7),      # MAGE3   - THE DODGE TEST: packs to $E3
    15: (7, 1, 7),      # MAGSAFE - the safe near-magenta: packs to $E7
    255: (0, 7, 0),     # GREEN   - must never be seen (see header)
}

BLACK, WHITE = 0, 1
G1, G2, G3, G4, G5, G6 = 2, 3, 4, 5, 6, 7
BROWN, DKRED, ORANGE, YELLOW, RED, SAND, MAGE3, MAGSAFE = range(8, 16)
TRANSP = 255

RAMP = [BLACK, G1, G2, G3, G4, G5, G6, WHITE]

# The one entry that is ALLOWED to collide with L2_TRANSP_COLOUR.
DODGE_INDEX = MAGE3


def pack0(rgb):
    r, g, b = rgb
    return (r << 5) | (g << 2) | (b >> 1)


def pal_bytes():
    out = bytearray()
    collide = []
    for i in range(256):
        r, g, b = COLOURS.get(i, (0, 0, 0))
        first = pack0((r, g, b))
        if first == 0xE3 and i != TRANSP:
            collide.append(i)
        out.append(first)
        out.append(b & 1)
    # The dodge test is only a test if exactly one entry arms it. Two
    # would make a hole in either block ambiguous; none would make the
    # "E3" block a plain magenta rectangle testing nothing.
    assert collide == [DODGE_INDEX], (
        "expected exactly one non-255 entry packing to $E3 (index %d), got %r"
        % (DODGE_INDEX, collide))
    assert pack0(COLOURS[TRANSP]) != 0xE3, (
        "entry 255 must NOT pack to $E3 here - it is the stamp-failure "
        "signature and the copy loop's dodge would rewrite it (see header)")
    return bytes(out)


# --- 5x7 font, only the glyphs the caption and labels need ---------
FONT = {
    ' ': ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
    'L': ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    'H': ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    'O': ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    'E': ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    'S': ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    '2': ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    '3': ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
    '7': ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
}

SCALE = 3
GLYPH_W, GLYPH_H, GAP = 5 * SCALE, 7 * SCALE, 3

CAPTION = "L2 HOLES"
CAPTION_TOP = 17

# --- holes ---------------------------------------------------------
# (tag, kind, params). The tag is the two characters the fixture writes
# into the text unit this hole uncovers - see the derived table printed
# by main().
HOLES = [
    ("TL", "rect", (0, 0, 31, 15)),           # corner: first bytes of row 0
    ("TR", "rect", (224, 0, 255, 15)),        # corner: last bytes of row 0
    ("BL", "rect", (0, 176, 31, 191)),        # corner: first bytes of row 191
    ("BR", "rect", (224, 176, 255, 191)),     # corner: last bytes of row 191
    ("E3", "none", ()),                       # the dodge block: NOT a hole
    ("E7", "none", ()),                       # the safe block: NOT a hole
    ("DG", "tri",  (32, 64, 48)),             # diagonal edge, 1px apex
    ("CT", "disc", (128, 96, 24)),            # centre, curved edge
    ("RN", "ring", (200, 88, 23, 6)),         # curved edge + opaque island
    ("32", "rect", (32, 128, 63, 159)),
    ("16", "rect", (112, 128, 127, 143)),
    ("08", "rect", (180, 128, 187, 135)),
    ("4C", "rect", (84, 136, 87, 143)),       # exactly one tilemap cell
    ("2P", "rect", (152, 136, 153, 137)),
    ("1P", "rect", (204, 136, 204, 136)),     # one byte
]

# Target patches: (x0, y0, x1, y1, cross_x, cross_y) - the crosshair
# points at the hole punched at its centre afterwards.
TARGETS = [
    (72, 128, 99, 151, 85, 139),      # around the 4x8 one-cell hole
    (140, 128, 167, 151, 152, 136),   # around the 2x2 hole
    (192, 128, 219, 151, 204, 136),   # around the 1x1 hole
]

# Dodge blocks: (index, label, x0, x1) on rows y 40..63 = tilemap 9..11.
DODGE_Y0, DODGE_Y1 = 40, 63
DODGE_BLOCKS = [(MAGE3, "E3", 68, 127), (MAGSAFE, "E7", 128, 187)]

RAMP_Y0, RAMP_Y1 = 160, 175
FINE_Y0, FINE_Y1 = 176, 191
FINE_X0, FINE_X1 = 32, 223


def hole_pixels(kind, p):
    if kind == "none":
        return
    if kind == "rect":
        x0, y0, x1, y1 = p
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                yield x, y
    elif kind == "tri":
        x0, y0, size = p
        for y in range(y0, y0 + size):
            for x in range(x0, x0 + size):
                if (x - x0) <= (y - y0):
                    yield x, y
    elif kind == "disc":
        cx, cy, r = p
        for y in range(cy - r, cy + r + 1):
            for x in range(cx - r, cx + r + 1):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    yield x, y
    elif kind == "ring":
        cx, cy, ro, ri = p
        for y in range(cy - ro, cy + ro + 1):
            for x in range(cx - ro, cx + ro + 1):
                d = (x - cx) ** 2 + (y - cy) ** 2
                if ri * ri < d <= ro * ro:
                    yield x, y
    else:
        raise AssertionError("unknown hole kind %r" % kind)


def fill(px, y0, y1, x0, x1, idx):
    for y in range(y0, y1 + 1):
        row = px[y]
        for x in range(x0, x1 + 1):
            row[x] = idx


def draw_text(px, text, left, top, colour):
    x = left
    for ch in text:
        glyph = FONT[ch]
        for gy in range(7):
            for gx in range(5):
                if glyph[gy][gx] != '1':
                    continue
                for sy in range(SCALE):
                    for sx in range(SCALE):
                        px[top + gy * SCALE + sy][x + gx * SCALE + sx] = colour
        x += GLYPH_W + GAP


def text_width(text):
    return len(text) * (GLYPH_W + GAP) - GAP


def build():
    px = [[BROWN] * WIDTH for _ in range(HEIGHT)]

    # 1. 32x32 checkerboard - the opaque field, and a tilemap-cell ruler
    for y in range(HEIGHT):
        for x in range(WIDTH):
            px[y][x] = BROWN if ((x >> 5) + (y >> 5)) & 1 == 0 else DKRED

    # 2. 8-step grey ramp, 32 px per step, on the same 32 px grid
    for i, c in enumerate(RAMP):
        fill(px, RAMP_Y0, RAMP_Y1, i * 32, i * 32 + 31, c)

    # 3. 2x2 checkerboard - the only one-byte-shift detector here
    for y in range(FINE_Y0, FINE_Y1 + 1):
        for x in range(FINE_X0, FINE_X1 + 1):
            px[y][x] = WHITE if ((x >> 1) + (y >> 1)) & 1 else DKRED

    # 4. grid lines, drawn OVER the ramp and the 2x2 band so their
    #    boundaries carry the same marks the field does
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if (x & 31) == 0 or (y & 31) == 0:
                px[y][x] = ORANGE

    # 5. the dodge test
    for idx, label, x0, x1 in DODGE_BLOCKS:
        fill(px, DODGE_Y0, DODGE_Y1, x0, x1, idx)
        w = text_width(label)
        draw_text(px, label, x0 + (x1 - x0 + 1 - w) // 2, DODGE_Y0 + 1, BLACK)

    # 6. target patches for the three sub-cell holes
    for x0, y0, x1, y1, cx, cy in TARGETS:
        fill(px, y0, y1, x0, x1, SAND)
        fill(px, cy, cy, x0, x1, RED)
        fill(px, y0, y1, cx, cx, RED)

    # 7. the caption
    draw_text(px, CAPTION, (WIDTH - text_width(CAPTION)) // 2,
              CAPTION_TOP, YELLOW)

    # 8. 2px frame - the card's extent, and a vertical-shift readout
    fill(px, 0, 1, 0, WIDTH - 1, WHITE)
    fill(px, HEIGHT - 2, HEIGHT - 1, 0, WIDTH - 1, WHITE)
    fill(px, 0, HEIGHT - 1, 0, 1, WHITE)
    fill(px, 0, HEIGHT - 1, WIDTH - 2, WIDTH - 1, WHITE)

    # 9. the holes, last, so they cut the frame and the crosshairs
    expected = set()
    for tag, kind, p in HOLES:
        for x, y in hole_pixels(kind, p):
            assert 0 <= x < WIDTH and 0 <= y < HEIGHT, \
                "hole %s leaves the card at (%d,%d)" % (tag, x, y)
            px[y][x] = TRANSP
            expected.add((x, y))

    flat = bytearray()
    for row in px:
        flat.extend(row)
    assert len(flat) == WIDTH * HEIGHT

    # Index 255 EXACTLY where intended and nowhere else. This is the one
    # assertion the whole card rests on: a stray 255 would be a hole the
    # run sheet does not name, and a missing one would be a hole the
    # owner is told to look for and cannot find.
    got = set((i % WIDTH, i // WIDTH) for i, v in enumerate(flat) if v == TRANSP)
    assert got == expected, (
        "index 255 appears in %d place(s) it should not and is missing from %d"
        % (len(got - expected), len(expected - got)))
    used = set(flat)
    assert used == set(COLOURS), (
        "indices used %r != indices given a colour %r"
        % (sorted(used), sorted(COLOURS)))
    return bytes(flat), expected


# --- the derived hole -> tilemap table -----------------------------
# tests\l2holes.dsf's text is written from this. Recomputed on every run
# so the two can never drift apart silently.
def cells(pixels):
    return set((x // 4 + 8, y // 8 + 4) for x, y in pixels)


def tag_report():
    lines = []
    for tag, kind, p in HOLES:
        pix = set(hole_pixels(kind, p))
        if not pix:
            lines.append("  %-3s (opaque block, rows 9..11)" % tag)
            continue
        cs = cells(pix)
        cols = sorted(set(c for c, r in cs))
        rows = sorted(set(r for c, r in cs))
        # A unit's NAME is readable only where the hole covers BOTH tag
        # columns of that unit on that row.
        named = []
        for u in range(10):
            tcols = (8 * u + 5, 8 * u + 6)
            urows = sorted(r for r in rows
                           if all((tc, r) in cs for tc in tcols))
            if urows:
                named.append("u%d rows %d-%d" % (u, urows[0], urows[-1]))
        lines.append("  %-3s cols %d-%d rows %d-%d  %d px  names: %s"
                     % (tag, cols[0], cols[-1], rows[0], rows[-1], len(pix),
                        ", ".join(named) if named else "(sub-unit)"))
    return lines


def decode_back(path):
    """Read the written file back and prove it from its own bytes."""
    data = open(path, "rb").read()
    print("decode-back of %s" % path)
    print("  %d bytes = 512 palette + %d pixels" % (len(data), len(data) - 512))
    assert (len(data) - 512) % WIDTH == 0, "not a whole number of 256-byte rows"
    rows = (len(data) - 512) // WIDTH
    print("  gfx_derive_height would derive %d rows (limit 1..192)" % rows)
    assert 1 <= rows <= 192 and rows == HEIGHT

    pal, pix = data[:512], data[512:]
    e3 = [i for i in range(256) if pal[2 * i] == 0xE3]
    print("  palette entries packing to $E3: %r  (l2_pal9_run rewrites "
          "these to $E2)" % e3)
    assert e3 == [DODGE_INDEX], "the dodge test is not armed as intended"
    r, g, b = COLOURS[DODGE_INDEX]
    print("    index %d authored RGB333 %s, byte0 $%02X byte1 $%02X -> after "
          "the dodge renders (%d,%d,%d)"
          % (DODGE_INDEX, (r, g, b), pal[2 * DODGE_INDEX],
             pal[2 * DODGE_INDEX + 1], 7, 0, ((0xE2 & 3) << 1) | (b & 1)))
    print("    index %d authored RGB333 %s, byte0 $%02X - untouched"
          % (MAGSAFE, COLOURS[MAGSAFE], pal[2 * MAGSAFE]))
    print("    index 255 authored RGB333 %s, byte0 $%02X - overwritten with "
          "$E3 by l2_pal9_stamp; visible only if that stamp fails"
          % (COLOURS[TRANSP], pal[510]))

    counts = {}
    for v in pix:
        counts[v] = counts.get(v, 0) + 1
    print("  indices used: %r" % sorted(counts))
    assert sorted(counts) == sorted(COLOURS)

    holes = set((i % WIDTH, i // WIDTH) for i, v in enumerate(pix) if v == TRANSP)
    print("  index 255 pixels: %d, in %d tilemap cells"
          % (len(holes), len(cells(holes))))
    per = {}
    for tag, kind, p in HOLES:
        pxs = set(hole_pixels(kind, p))
        if pxs:
            per[tag] = pxs
    covered = set()
    for tag, pxs in per.items():
        assert pxs <= holes, "hole %s is not fully transparent in the file" % tag
        covered |= pxs
    assert covered == holes, "the file has transparent pixels no hole claims"
    print("  every 255 pixel belongs to exactly one named hole, and every "
          "named hole is fully transparent")
    print("  hole -> tilemap map (fixture text is written from this):")
    for line in tag_report():
        print(line)
    print("  card footprint: tilemap cols 8-71 rows 4-27; control margin "
          "cols 0-7/72-79 rows 0-3/28-31")


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(outdir, exist_ok=True)
    pixels, _ = build()
    data = pal_bytes() + pixels
    assert (len(data) - 512) % WIDTH == 0
    assert (len(data) - 512) // WIDTH == HEIGHT
    path = os.path.join(outdir, "l2holes.nxi")
    with open(path, "wb") as f:
        f.write(data)
    print("wrote %s  %d bytes  %dx%d  %d palette entries used"
          % (path, len(data), WIDTH, HEIGHT, len(COLOURS)))
    decode_back(path)


if __name__ == "__main__":
    main()
