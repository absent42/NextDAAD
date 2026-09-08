# Fixture art for the intro compiler selftest and the -Intro harness leg.
# Paletted PNGs via mkanisheets.write_png; a row-major NX2 built by hand
# for the transpose check; a 2 s stereo WAV for the PCM leg.
import os, struct, sys, math
sys.path.insert(0, os.path.dirname(__file__))
from mkanisheets import write_png

MAGENTA = (255, 0, 255)

def pal_a():
    return [((i * 7) & 255, (i * 3) & 255, (i * 11) & 255) for i in range(256)]

def pal_b():
    return [((i * 13) & 255, 255 - i, (i * 5) & 255) for i in range(256)]

def pic(w, h, f):
    return [[f(x, y) & 255 for x in range(w)] for y in range(h)]

def write_nx2(path, pal, rows):
    # row-major NX2: 512-byte palette (RRRGGGBB, blue LSB) then pixels
    out = bytearray()
    for (r, g, b) in pal:
        out.append((r & 0xE0) | ((g & 0xE0) >> 3) | ((b & 0xC0) >> 6))
        out.append((b >> 5) & 1)
    for row in rows:
        out.extend(bytes(row))
    with open(path, "wb") as f:
        f.write(out)

def write_wav(path, seconds=2, rate=44100):
    n = seconds * rate
    data = bytearray()
    for i in range(n):
        l = int(12000 * math.sin(2 * math.pi * 440 * i / rate))
        r = int(12000 * math.sin(2 * math.pi * 880 * i / rate))
        data += struct.pack("<hh", l, r)
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 4, 4, 16)
    hdr += b"data" + struct.pack("<I", len(data))
    with open(path, "wb") as f:
        f.write(hdr + data)

def main(out):
    os.makedirs(out, exist_ok=True)
    a, b = pal_a(), pal_b()
    write_png(os.path.join(out, "p320a.png"), 320, 256, a, pic(320, 256, lambda x, y: x + y))
    write_png(os.path.join(out, "p320b.png"), 320, 256, b, pic(320, 256, lambda x, y: x ^ y))
    write_png(os.path.join(out, "p320c.png"), 320, 256, a, pic(320, 256, lambda x, y: x * 3 + y))
    write_png(os.path.join(out, "p256a.png"), 256, 192, a, pic(256, 192, lambda x, y: x + 2 * y))
    write_png(os.path.join(out, "bad300.png"), 300, 256, a, pic(300, 256, lambda x, y: x))
    # font sheet: 16 colours, magenta at PLTE index 5; glyph n uses colour (n % 15) + 1
    # except colour 5 (magenta) which is skipped, so every glyph is opaque except
    # glyph 0 and glyph 32 (space), which are all magenta (transparent)
    fpal = [(0, 0, 0), (255, 255, 255), (255, 0, 0), (0, 255, 0), (0, 0, 255), MAGENTA,
            (255, 255, 0), (0, 255, 255), (128, 128, 128), (64, 64, 64), (192, 192, 192),
            (128, 0, 0), (0, 128, 0), (0, 0, 128), (128, 128, 0), (0, 128, 128)]
    def fpix(x, y):
        n = (y // 8) * 16 + (x // 8)
        if n == 0 or n == 32:
            return 5
        c = n % 15
        return c + 1 if c + 1 != 5 else 6
    write_png(os.path.join(out, "font.png"), 128, 128, fpal, pic(128, 128, fpix))
    write_nx2(os.path.join(out, "ready320.NX2"), a, pic(320, 256, lambda x, y: x + y))
    write_wav(os.path.join(out, "tone.wav"))

if __name__ == "__main__":
    main(sys.argv[1])
