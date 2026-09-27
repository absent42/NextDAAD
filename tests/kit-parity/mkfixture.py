# Generates the binary half of the parity fixture. Text files live beside
# it in fixture/; this writes what git should not hold (PNG, WAV, fonts, mp4).
import os, shutil, struct, subprocess, sys, zlib, math

def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

def write_png(path, width, height, palette, pixels):
    raw = b"".join(b"\x00" + bytes(row) for row in pixels)
    plte = b"".join(bytes(c) for c in palette)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"PLTE", plte)
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

def gradient_png(path, width, height, seed):
    # 256-entry palette, deterministic bands so every index is used.
    pal = [((i * 7 + seed) & 255, (i * 3) & 255, (255 - i) & 255) for i in range(256)]
    px = [[((x // 4) + (y // 8) + seed) & 255 for x in range(width)] for y in range(height)]
    write_png(path, width, height, pal, px)

def pointer_png(path):
    pal = [(255, 0, 255), (0, 0, 0), (255, 255, 255)] + [(0, 0, 0)] * 253
    px = [[0] * 16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            if x <= y // 2 + 1 and y < 12:
                px[y][x] = 2 if x == 0 or x == y // 2 + 1 else 1
    write_png(path, 16, 16, pal, px)

def wav_u8_mono(path, rate, hz, nbytes):
    cycles = round(hz * nbytes / rate)
    pcm = bytes(min(255, max(0, int(math.floor(128 + 127 * math.sin(2 * math.pi * cycles * n / nbytes) + 0.5)))) for n in range(nbytes))
    hdr = (b"RIFF" + struct.pack("<I", 36 + nbytes) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate, 1, 8)
           + b"data" + struct.pack("<I", nbytes))
    with open(path, "wb") as f:
        f.write(hdr + pcm)

def glyph_rows(code):
    # 8x8 box with the low three bits of the code as a bar pattern: distinct per glyph.
    return [0xFF] + [0x81 | ((code & 7) << 3)] * 6 + [0xFF]

def write_psf1(path):
    # PSF1: magic 36 04, mode 0, charsize 8, then 256 glyphs of 8 bytes.
    with open(path, "wb") as f:
        f.write(bytes([0x36, 0x04, 0, 8]))
        for c in range(256):
            f.write(bytes(glyph_rows(c)))

def write_bdf(path):
    lines = ["STARTFONT 2.1", "FONT -parity-fixed-medium-r-normal--8-80-75-75-c-80-iso8859-1",
             "SIZE 8 75 75", "FONTBOUNDINGBOX 8 8 0 0", "CHARS 96"]
    for c in range(32, 128):
        lines += ["STARTCHAR U+%04X" % c, "ENCODING %d" % c, "SWIDTH 500 0", "DWIDTH 8 0",
                  "BBX 8 8 0 0", "BITMAP"] + ["%02X" % b for b in glyph_rows(c)] + ["ENDCHAR"]
    lines.append("ENDFONT")
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

def write_mp4(path, ffmpeg, frames_dir):
    # Lossless RGB H.264, no audio: decode is normative, no swscale, no swresample.
    for i in range(50):
        gradient_png(os.path.join(frames_dir, "f%03d.png" % i), 320, 256, i * 5)
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-framerate", "25",
           "-i", os.path.join(frames_dir, "f%03d.png"), "-c:v", "libx264rgb", "-qp", "0",
           "-pix_fmt", "rgb24", "-an", path]
    subprocess.run(cmd, check=True)

def make_sprites(out, sprites):
    # mkanisheets.main also writes 008 (must-fail) and 015 (palette conflict),
    # negative fixtures for another test that would break this kit build.
    # Generate into a scratch dir and copy only 002 and 006 into SPRITES.
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(here, "..", "art"))
    import mkanisheets
    scratch = os.path.join(out, "_sheets")
    os.makedirs(scratch, exist_ok=True)
    try:
        mkanisheets.main(scratch)
    except SystemExit:
        pass
    for stem in ("002", "006"):
        for ext in (".png", ".txt"):
            shutil.copyfile(os.path.join(scratch, stem + ext), os.path.join(sprites, stem + ext))
    for n in os.listdir(scratch):
        os.remove(os.path.join(scratch, n))
    os.rmdir(scratch)

def main(argv):
    out = argv[1]
    ffmpeg = argv[argv.index("--ffmpeg") + 1]
    sprites = os.path.join(out, "IMAGES", "SPRITES")
    os.makedirs(sprites, exist_ok=True)
    os.makedirs(os.path.join(out, "AUDIO"), exist_ok=True)
    os.makedirs(os.path.join(out, "VIDEO"), exist_ok=True)
    gradient_png(os.path.join(out, "IMAGES", "DAAD.png"), 320, 256, 1)
    gradient_png(os.path.join(out, "IMAGES", "001.png"), 320, 256, 2)
    gradient_png(os.path.join(out, "IMAGES", "002.png"), 256, 192, 3)
    pointer_png(os.path.join(out, "IMAGES", "POINTER.png"))
    make_sprites(out, sprites)
    wav_u8_mono(os.path.join(out, "AUDIO", "001.wav"), 15625, 440, 15625)
    write_psf1(os.path.join(out, "FONT.psf"))
    write_bdf(os.path.join(out, "FONT1.bdf"))
    frames = os.path.join(out, "_frames")
    os.makedirs(frames, exist_ok=True)
    write_mp4(os.path.join(out, "VIDEO", "001.mp4"), ffmpeg, frames)
    for n in os.listdir(frames):
        os.remove(os.path.join(frames, n))
    os.rmdir(frames)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
