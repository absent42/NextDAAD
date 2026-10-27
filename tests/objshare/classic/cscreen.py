"""Text off a CPC mode 1 screen or an MSX TMS9918 VRAM dump, by glyph match.

Shared by drive_cpc.py and drive_msx1.py. Cells are 8 pixels tall; the
column width and the font are per machine. The line editor's caret (a
solid or partly solid block, not a font glyph) decodes as zscreen.CURSOR
so zleg's cursor and prompt helpers apply unchanged.
"""
import re
import struct
import zlib
from pathlib import Path

CURSOR = "_"


def load_font(path, width=8):
    """DAAD .CHR (8 bytes per code) -> {cell tuple: char}, codes 32-127.

    width 6 keeps the top six bits of each row (AD8x6.CHR layout).
    """
    data = Path(path).read_bytes()
    shift = 8 - width
    mask = (1 << width) - 1
    table = {}
    for code in range(32, 128):
        g = data[code * 8:code * 8 + 8]
        if len(g) < 8:
            break
        table.setdefault(tuple((b >> shift) & mask for b in g), chr(code))
    return table


def is_caret(cell, width):
    """A cell whose rows are all either full or empty, with some full."""
    full = (1 << width) - 1
    return any(r == full for r in cell) and all(r in (0, full) for r in cell)


def decode_rows(rows, width, table, cols, dy, total):
    """rows: scanline ints, MSB = leftmost of `total` pixels."""
    out = []
    mask = (1 << width) - 1
    for r in range((len(rows) - dy) // 8):
        line = []
        for c in range(cols):
            sh = total - (c + 1) * width
            if sh < 0:
                break
            cell = tuple((rows[dy + r * 8 + i] >> sh) & mask
                         for i in range(8))
            if cell == (0,) * 8:
                line.append(" ")
            elif cell in table:
                line.append(table[cell])
            elif is_caret(cell, width):
                line.append(CURSOR)
            else:
                line.append("?")
        out.append("".join(line).rstrip())
    return out


def score(lines):
    text = "".join(lines)
    return (text.count("?"), -sum(1 for ch in text if ch != " "))


def fold_l1(line):
    """AD8x8.CHR draws '1' and 'l' alike: a run of them next to a letter
    is 'l', otherwise '1'."""
    return re.sub(r"(?<=[A-Za-z])1+|1+(?=[A-Za-z])",
                  lambda m: "l" * len(m.group(0)), line)


def decode(rows, width, table, cols, total, keep_blank=False, l1=False):
    """Best vertical phase; blank lines dropped (see zscreen.decode)."""
    best = best_s = None
    for dy in range(8):
        lines = decode_rows(rows, width, table, cols, dy, total)
        s = score(lines)
        if best_s is None or s < best_s:
            best, best_s = lines, s
    if l1:
        best = [fold_l1(l) for l in best]
    return best if keep_blank else [l for l in best if l.strip()]


# ---- CPC mode 1 -----------------------------------------------------------

CPC_W, CPC_H = 320, 200


def cpc_pixels(scr):
    """16K at &C000 -> 200 rows of 320 pen numbers (mode 1)."""
    rows = []
    for y in range(CPC_H):
        base = (y % 8) * 0x800 + (y // 8) * 80
        row = []
        for b in scr[base:base + 80]:
            for s in range(4):
                row.append(((b >> (7 - s)) & 1) | (((b >> (3 - s)) & 1) << 1))
        rows.append(row)
    return rows


def ink_rows(pix):
    """Pen grid -> scanline ints, ink = any pen but the commonest one."""
    counts = {}
    for row in pix:
        for p in row:
            counts[p] = counts.get(p, 0) + 1
    paper = max(counts, key=counts.get)
    out = []
    for row in pix:
        v = 0
        for p in row:
            v = (v << 1) | (p != paper)
        out.append(v)
    return out


# ---- MSX screen 2 (graphic II) ------------------------------------------

TMS_PAL = [(0, 0, 0), (0, 0, 0), (33, 200, 66), (94, 220, 120),
           (84, 85, 237), (125, 118, 252), (212, 82, 77), (66, 235, 245),
           (252, 85, 84), (255, 121, 120), (212, 193, 84), (230, 206, 128),
           (33, 176, 59), (201, 91, 186), (204, 204, 204), (255, 255, 255)]


def msx_g2(vram, name=0x1800, pat=0x0000, col=0x2000):
    """Graphic II VRAM -> (192 scanline ints of 256 px, rgb rows).

    Ink = pattern bit set; PNG colours from the colour table and the
    TMS9918 palette (an MSX2 palette change is not modelled).
    """
    rows, rgb = [], []
    for y in range(192):
        third, line, v, px = y // 64, y % 8, 0, []
        for cx in range(32):
            n = vram[name + (y // 8) * 32 + cx]
            a = third * 2048 + n * 8 + line
            b, c = vram[pat + a], vram[col + a]
            v = (v << 8) | b
            for i in range(8):
                px.append(TMS_PAL[(c >> 4) if b >> (7 - i) & 1 else c & 15])
        rows.append(v)
        rgb.append(px)
    return rows, rgb


# ---- PNG ----------------------------------------------------------------

def write_png(path, rgb_rows):
    """rgb_rows: list of rows, each a list of (r, g, b)."""
    h, w = len(rgb_rows), len(rgb_rows[0])
    raw = bytearray()
    for row in rgb_rows:
        raw.append(0)
        for px in row:
            raw.extend(px)

    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b""))


def bmp_to_png(bmp_path, png_path):
    """24-bit uncompressed BMP (ZEsarUX save-screen) -> PNG."""
    d = Path(bmp_path).read_bytes()
    off, = struct.unpack_from("<I", d, 10)
    w, h = struct.unpack_from("<ii", d, 18)
    bpp, = struct.unpack_from("<H", d, 28)
    if bpp != 24:
        raise ValueError("%s: %d bpp, want 24" % (bmp_path, bpp))
    stride = (w * 3 + 3) & ~3
    rows = []
    for y in range(abs(h)):
        sy = abs(h) - 1 - y if h > 0 else y
        p = off + sy * stride
        line = d[p:p + w * 3]
        rows.append([(line[i + 2], line[i + 1], line[i])
                     for i in range(0, w * 3, 3)])
    write_png(png_path, rows)
