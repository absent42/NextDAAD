# Layer 2 TRANSPARENCY instrument - punch-out card for the hole/hardware
# fixture (tests\l2holes.dsf), staged as sd\L2HOLES\001.NXI over a
# tilemap of position-naming text. Inverse of mkl2card.py: that card has
# no index-255 pixel (any transparency is damage); this one punches 13
# holes at index 255 (a hole not showing text through it is damage).
#
# THE DODGE RULE (canonical here - other headers cite it by name). 255
# (L2_TRANSP_INDEX, src\nextdaad.inc) is the only pixel value
# l2_pal9_stamp (src\overlay2.asm) forces to $E3 (L2_TRANSP_COLOUR, a
# colour compare on the palette output, not an index compare) after
# every load. Any OTHER entry packing to $E3 would punch an unwanted
# hole - real, since saturated magenta already appears in corpus art -
# so l2_pal9_run/l2_palette_load rewrite such entries to $E7 (one green
# step) before the stamp re-forces 255 back to $E3. PASS: an entry
# authored at $E3 (other than 255) renders identically to one at $E7 -
# proven by the "E3"/"E7" blocks below.
#
# GEOMETRY. 256x192, full screen; Layer 2 is inset 32px from the tilemap
# (column = x//4+8, row = y//8+4), covering columns 8-71, rows 4-27.
#
# HOLES (tag: what it targets):
#   TL/TR/BL/BR  32x16 corners     - first/last byte of first/last row
#   DG   48x48 diagonal, 1px apex  - finest edge case
#   CT   disc r24 @ centre         - curved edge, no stepped blitter
#   RN   ring r23/r6               - opaque island: per-pixel, not flood
#   32/16/08  size-ladder squares  - progressively smaller
#   4C   4x8 (one tilemap cell)    - smallest hole showing a character
#   2P/1P  2x2 / 1x1               - odd-shift phase / single-byte
#   E3/E7  (not holes, rows 9-11)  - the dodge test blocks
# Sand+crosshair patches mark the 4C/2P/1P holes for by-eye spotting.
#
# Opaque field (checkerboard ruler, grey ramp, 2x2 checker, caption,
# white frame) is never flat, so each piece's absence or displacement is
# visible on its own. Two more sentinels: no flat area is dark blue
# (tilemap PAPER 1), so blue in the footprint is a hole; entry 255 here
# is bright green, used nowhere else, so green instead of text means
# l2_pal9_stamp did not run.
#
# FILE FORMAT: 512-byte palette then row-major indices, same as
# mkl2card.py; hand-authored so $E3 stays under this card's control.

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
          "these to $E7)" % e3)
    assert e3 == [DODGE_INDEX], "the dodge test is not armed as intended"
    r, g, b = COLOURS[DODGE_INDEX]
    print("    index %d authored RGB333 %s, byte0 $%02X byte1 $%02X -> after "
          "the dodge renders (%d,%d,%d) - identical to the E7 control"
          % (DODGE_INDEX, (r, g, b), pal[2 * DODGE_INDEX],
             pal[2 * DODGE_INDEX + 1], 7, 1, ((0xE7 & 3) << 1) | (b & 1)))
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
