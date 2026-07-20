#!/usr/bin/env python3
"""
tests/gen_vid_synth.py - SP13 T2/T3: generate spec-compliant MakeVid
palette-format fixtures (256x192 format 4, 256x240 format 2) from their
KNOWN-GOOD no-palette siblings (formats 5 and 3 respectively).

MakeVid 1.77's own "autopal" encodes are malformed: they carry raw RGB24
pixel data, never converted to indexed colour (e.g. 256x192 RGB24 =
147456 B vs the format's 49152-byte pixel slot, so each "frame" holds
only the top third of the image; decoded straight, that top third is a
pristine PNG of the test card). The suspected mechanism is MakeVid's
IrfanView-dependent custom-palette pipeline silently falling back to raw
frames. Three independent renderers (this project's player, playvid
itself, and an offline decode) garble these files identically - see the
SP13 T2 report's "Format 4 garble" section for the full diagnosis and
tests/build-tests.ps1's -Vid header comment. This script sidesteps the
broken encoder entirely: it reads the matching no-palette source (READ-
ONLY, NEVER written to - tools/ is the gitignored, unrecoverable build
toolchain) and re-packs each of its frames with a synthetic IDENTITY
9-bit palette inserted, producing a genuinely spec-compliant palette-
format file whose pixel content is IDENTICAL to the no-palette source.

Originally written for format 4 only (SP13 T2); generalized here (SP13
T3) to cover format 2 as well - both share the exact same technique,
differing only in the audio+pad/pixel byte counts. Frame layout
(nextdaad.inc; tools/ZXNextOS/src/c/DotCommands/playvid/video_256x192_m.
asm/_palette.asm and video_256x240.asm/_palette.asm):
  format 5 (source) = 50176 B: audio(933) + pad(91) + pixels(49152)
  format 4 (output) = 50688 B: audio(933) + pad(91) + palette(512)
                                 + pixels(49152)
  format 3 (source) = 65536 B: audio(3732) + pad(364) + pixels(61440)
  format 2 (output) = 66048 B: audio(3732) + pad(364) + palette(512)
                                 + pixels(61440)
Both pairs share the same audio+pad and pixel bytes verbatim - only the
512-byte palette block is inserted between them.

Palette block: 256 entries x 2 bytes, NR $44 write order (byte0 =
RRRGGGBB, byte1 bit0 = expanded 9th blue bit, bit7 = L2 priority = 0).
The blue expansion matches the Next's own 8-bit (NR $41) -> 9-bit
hardware rule exactly: "least significant bit of blue is set to OR
between B2 and B1" (docs/zx-next-dev-guide-2022-07-15/chapter-next-
palette.tex:176) - for entry i, the two blue bits are (i & 3), so the
extra bit is 1 iff (i & 3) != 0. entry[i].byte0 = i (identity - the
no-palette source's pixel byte IS its own colour, matching the
interpreter's own vid_identity_palette convention, src/video.asm).

Usage: python gen_vid_synth.py <fmt> [source] [dest]
  fmt = 4 (256x192) or 2 (256x240)
  defaults (fmt 4): source = tools/demo-files/001_256x192auto[c10g10s10].vid
                     dest   = sd/005.VID
  defaults (fmt 2): source = tools/demo-files/001_256x240auto[c10g10s10].vid
                     dest   = sd/003.VID
Paths are resolved relative to this script's own directory's parent
(the repo root), so it can be invoked from any working directory.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (audio+pad bytes, pixel bytes, source format number, default source
# name, default dest name)
FORMATS = {
    "4": (933 + 91, 49152, 5,
          "001_256x192auto[c10g10s10].vid", "005.VID"),
    "2": (3732 + 364, 61440, 3,
          "001_256x240auto[c10g10s10].vid", "003.VID"),
}
PALETTE = 512


def identity_palette_9bit():
    """256 entries x 2 bytes: byte0 = i (RRRGGGBB, identity), byte1 =
    the expanded 9th blue bit only (OR of the two blue bits - i & 3 !=
    0), bit7 (L2 priority) left 0. See the module docstring for the
    hardware rule this matches."""
    out = bytearray(512)
    for i in range(256):
        out[i * 2] = i
        out[i * 2 + 1] = 1 if (i & 3) != 0 else 0
    return bytes(out)


def main(argv):
    if len(argv) < 2 or argv[1] not in FORMATS:
        print("usage: gen_vid_synth.py <4|2> [source] [dest]")
        return 1
    audio_pad, pixels, src_fmt, def_src, def_dst = FORMATS[argv[1]]
    src_frame = audio_pad + pixels
    dst_frame = audio_pad + PALETTE + pixels

    src_path = Path(argv[2]) if len(argv) > 2 else ROOT / "tools" / "demo-files" / def_src
    dst_path = Path(argv[3]) if len(argv) > 3 else ROOT / "sd" / def_dst

    data = src_path.read_bytes()

    whole_frames = len(data) // src_frame
    used = whole_frames * src_frame
    if used < len(data):
        print(f"truncating source: {len(data)} -> {used} bytes "
              f"({len(data) - used} tail bytes dropped, "
              f"{whole_frames} whole fmt{src_fmt} frames)")

    palette = identity_palette_9bit()

    dst_path.parent.mkdir(parents=True, exist_ok=True)
    with open(dst_path, "wb") as out:
        for n in range(whole_frames):
            frame = data[n * src_frame:(n + 1) * src_frame]
            out.write(frame[:audio_pad])           # audio + pad, verbatim
            out.write(palette)                     # synthetic identity palette
            out.write(frame[audio_pad:src_frame])   # pixels, verbatim

    out_size = whole_frames * dst_frame
    assert out_size % 512 == 0, "output size must be a whole number of sectors"
    assert out_size % dst_frame == 0, "output size must be a whole number of frames"
    print(f"wrote {dst_path}: {whole_frames} frames x {dst_frame} B "
          f"= {out_size} B (fmt{argv[1]})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
