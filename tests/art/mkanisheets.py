# Fixture sprite sheets for tests\anipack-selftest.ps1. Paletted PNGs
# written by hand; palette entry 0 is magenta (transparent).
import os, struct, sys, zlib

MAGENTA = (255, 0, 255)

def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

def write_png(path, width, height, palette, pixels):
    """pixels: list of rows, each a list of palette indices."""
    raw = b"".join(b"\x00" + bytes(row) for row in pixels)
    plte = b"".join(bytes(c) for c in palette)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"PLTE", plte)
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

def write_txt(path, **keys):
    with open(path, "w") as f:
        for k, v in keys.items():
            f.write("%s=%s\n" % (k, v))

def fill(width, height, index):
    return [[index] * width for _ in range(height)]

def paste(pixels, x0, y0, block):
    for dy, row in enumerate(block):
        pixels[y0 + dy][x0:x0 + len(row)] = row

def main(out):
    os.makedirs(out, exist_ok=True)
    # 001: probe sheet. 48x32, six 16x16 cells, cell k filled with index k+1,
    # so the .spr byte order reveals gfx2next's cell order and index passthrough.
    pal = [MAGENTA] + [(i * 8, 0, 0) for i in range(1, 7)] + [(0, 0, 0)] * 249
    px = fill(48, 32, 0)
    for k in range(6):
        paste(px, (k % 3) * 16, (k // 3) * 16, fill(16, 16, k + 1))
    write_png(os.path.join(out, "001.png"), 48, 32, pal, px)
    write_txt(os.path.join(out, "001.txt"), w=16, h=16)
    # 002: torch. 32x16, two 16x16 frames; frame 0 index 1 with a magenta
    # top-left pixel, frame 1 index 2. Two patterns, no dedupe.
    pal = [MAGENTA, (255, 128, 0), (255, 255, 0)] + [(0, 0, 0)] * 253
    px = fill(32, 16, 1)
    paste(px, 16, 0, fill(16, 16, 2))
    px[0][0] = 0
    write_png(os.path.join(out, "002.png"), 32, 16, pal, px)
    write_txt(os.path.join(out, "002.txt"), w=16, h=16, x=24, y=180, delay="6,12", loop=1)
    # 003: dedupe + hidden cell. 64x32 sheet, w=h=32, two frames.
    # Frame 0 cells: 0=index1, 1=index2, 2=magenta (hidden), 3=index1 (dupe of cell 0).
    # Frame 1: same but cell 3 = index 3. Cells: 0->p0, 1->p1, 2->255, 3->p0 / p2.
    pal = [MAGENTA, (0, 255, 0), (0, 0, 255), (255, 255, 255)] + [(0, 0, 0)] * 252
    px = fill(64, 32, 0)
    for fx, c3 in ((0, 1), (32, 3)):
        paste(px, fx, 0, fill(16, 16, 1)); paste(px, fx + 16, 0, fill(16, 16, 2))
        paste(px, fx + 16, 16, fill(16, 16, c3))
    write_png(os.path.join(out, "003.png"), 64, 32, pal, px)
    write_txt(os.path.join(out, "003.txt"), w=32, h=32, delay=5, loop=0)
    # 004: blank-anchor substitution. 16x16 single frame, all magenta.
    write_png(os.path.join(out, "004.png"), 16, 16, [MAGENTA] + [(0, 0, 0)] * 255, fill(16, 16, 0))
    write_txt(os.path.join(out, "004.txt"), w=16, h=16)
    # 005: dodge. 16x16, opaque (224,0,192) truncates to RGB332 $E3 and must dodge to $E7.
    write_png(os.path.join(out, "005.png"), 16, 16, [MAGENTA, (224, 0, 192)] + [(0, 0, 0)] * 254, fill(16, 16, 1))
    write_txt(os.path.join(out, "005.txt"), w=16, h=16, bits=8)
    # 006: 4-bit multi-block. 32x16, w=h=16, two frames. Frame 0 uses colours 1-10,
    # frame 1 uses colours 11-20: two blocks of 10, no cell over 15.
    pal = [MAGENTA] + [(i * 12, 255 - i * 12, 64) for i in range(1, 21)] + [(0, 0, 0)] * 235
    px = fill(32, 16, 0)
    for f in range(2):
        for y in range(16):
            for x in range(16):
                px[y][f * 16 + x] = 1 + f * 10 + (x + y) % 10
    write_png(os.path.join(out, "006.png"), 32, 16, pal, px)
    write_txt(os.path.join(out, "006.txt"), w=16, h=16)
    # 007: one cell with 16 opaque colours: auto falls back to 8-bit, bits=4 must fail.
    pal = [MAGENTA] + [(i * 15, i * 15, i * 15) for i in range(1, 17)] + [(0, 0, 0)] * 239
    px = [[1 + (x + y) % 16 for x in range(16)] for y in range(16)]
    write_png(os.path.join(out, "007.png"), 16, 16, pal, px)
    write_txt(os.path.join(out, "007.txt"), w=16, h=16)
    write_png(os.path.join(out, "008.png"), 16, 16, pal, px)
    write_txt(os.path.join(out, "008.txt"), w=16, h=16, bits=4)
    # 009: sheetw. 32x32 sheet holding four 16x16 frames, two per row.
    pal = [MAGENTA, (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)] + [(0, 0, 0)] * 251
    px = fill(32, 32, 0)
    for k in range(4):
        paste(px, (k % 2) * 16, (k // 2) * 16, fill(16, 16, k + 1))
    write_png(os.path.join(out, "009.png"), 32, 32, pal, px)
    write_txt(os.path.join(out, "009.txt"), w=16, h=16, sheetw=32)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.join("tests", "out", "anipack")))
