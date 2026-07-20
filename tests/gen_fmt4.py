#!/usr/bin/env python3
"""
tests/gen_fmt4.py - SP13 T2 closing wave: generate a spec-compliant
MakeVid format-4 (256x192, 25fps, palette) fixture from the KNOWN-GOOD
format-5 (256x192, no-palette) source fixture.

MakeVid 1.77's own "autopal" encodes are malformed: they carry raw RGB24
pixel data, never converted to indexed colour (256x192 RGB24 = 147456 B
vs the format's 49152-byte pixel slot, so each "frame" holds only the
top third of the image, decoded straight it is a pristine PNG of the
test card's top third). The suspected mechanism is MakeVid's IrfanView-
dependent custom-palette pipeline silently falling back to raw frames.
Three independent renderers (this project's player, and playvid itself)
garble these files identically - see the SP13 T2 report's "Format 4
garble" section for the full diagnosis and tests/build-tests.ps1's -Vid
header comment. This script sidesteps the broken encoder entirely: it
reads tools/demo-files' 001_256x192auto[...].vid (READ-ONLY, NEVER
written to - tools/ is the gitignored, unrecoverable build toolchain)
and re-packs each of its frames with a synthetic IDENTITY 9-bit palette
inserted, producing a genuinely spec-compliant format-4 file whose pixel
content is IDENTICAL to the no-palette format-5 source.

Frame layout (nextdaad.inc; tools/ZXNextOS/src/c/DotCommands/playvid/
video_256x192_m.asm and video_256x192_m_palette.asm):
  format 5 (source) frame = 50176 B: audio(933) + pad(91) + pixels(49152)
  format 4 (output) frame = 50688 B: audio(933) + pad(91) + palette(512)
                                       + pixels(49152)
Both share the same audio+pad and pixel bytes verbatim - only the
512-byte palette block is inserted between them.

Palette block: 256 entries x 2 bytes, NR $44 write order (byte0 =
RRRGGGBB, byte1 bit0 = expanded 9th blue bit, bit7 = L2 priority = 0).
The blue expansion matches the Next's own 8-bit (NR $41) -> 9-bit
hardware rule exactly: "least significant bit of blue is set to OR
between B2 and B1" (docs/zx-next-dev-guide-2022-07-15/chapter-next-
palette.tex:176) - for entry i, the two blue bits are (i & 3), so the
extra bit is 1 iff (i & 3) != 0. entry[i].byte0 = i (identity - the
fmt5 pixel byte IS its own colour, matching the interpreter's own
vid_identity_palette convention, src/video.asm).

Usage: python gen_fmt4.py [source] [dest]
Defaults match this project's layout:
  source = tools/demo-files/001_256x192auto[c10g10s10].vid
  dest   = sd/005.VID
Paths are resolved relative to this script's own directory's parent
(the repo root), so it can be invoked from any working directory.
"""
import sys
from pathlib import Path

AUDIO_PAD = 933 + 91                       # 1024
PIXELS = 49152
SRC_FRAME = AUDIO_PAD + PIXELS             # 50176 (format 5)
PALETTE = 512
DST_FRAME = AUDIO_PAD + PALETTE + PIXELS   # 50688 (format 4, 99 sectors)

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SRC = ROOT / "tools" / "demo-files" / "001_256x192auto[c10g10s10].vid"
DEFAULT_DST = ROOT / "sd" / "005.VID"


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
    src_path = Path(argv[1]) if len(argv) > 1 else DEFAULT_SRC
    dst_path = Path(argv[2]) if len(argv) > 2 else DEFAULT_DST

    data = src_path.read_bytes()

    whole_frames = len(data) // SRC_FRAME
    used = whole_frames * SRC_FRAME
    if used < len(data):
        print(f"truncating source: {len(data)} -> {used} bytes "
              f"({len(data) - used} tail bytes dropped, "
              f"{whole_frames} whole fmt5 frames)")

    palette = identity_palette_9bit()

    dst_path.parent.mkdir(parents=True, exist_ok=True)
    with open(dst_path, "wb") as out:
        for n in range(whole_frames):
            frame = data[n * SRC_FRAME:(n + 1) * SRC_FRAME]
            out.write(frame[:AUDIO_PAD])           # audio + pad, verbatim
            out.write(palette)                     # synthetic identity palette
            out.write(frame[AUDIO_PAD:SRC_FRAME])  # pixels, verbatim

    out_size = whole_frames * DST_FRAME
    assert out_size % 512 == 0, "output size must be a whole number of sectors"
    assert out_size % DST_FRAME == 0, "output size must be a whole number of frames"
    print(f"wrote {dst_path}: {whole_frames} frames x {DST_FRAME} B "
          f"= {out_size} B (99 sectors/frame, fmt4)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
