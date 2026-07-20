#!/usr/bin/env python3
"""
tests/videnc.py - open-source encoder for MakeVid/playvid .VID format
(all six playback formats: 0-5).

Sync convention: authoring-kit/lib/videnc.py is a kit copy of this
file - its ENCODING LOGIC must stay identical to this one; only its
docstring and --help text may differ. Port any logic fix to both.

Why this exists: MakeVid 1.77's own palette ("autopal") encodes are
broken - their pixel slots hold raw, un-quantized RGB24 data, never
converted to palette indices (diagnosed offline, SP13 T2 report's
"Format 4 garble" section: 256x192 RGB24 = 147456 bytes against the
format's 49152-byte pixel slot, so a decoded "frame" is only the top
third of a real picture). This encoder builds spec-compliant .VID files
directly from any video ffmpeg can read, using Pillow's own adaptive
quantizer for the palette formats - no MakeVid, no IrfanView dependency.

Requires: Python 3, Pillow (for ADAPTIVE 256-colour quantization and the
transpose-based column-major reorder). Everything else is standard
library. An ffmpeg binary is required at run time (default: the
project's own tools\\ffmpeg\\bin\\ffmpeg.exe, override with --ffmpeg).

FORMAT TABLE (playvid README.TXT; video_*.asm headers in
tools\\ZXNextOS\\src\\c\\DotCommands\\playvid; SP13 T2/T3 forensic
reports in .superpowers\\sdd):

  fmt  size       palette  audio      pad   pixels  sectors  order
  0    320x240    yes      1866 B     182   76800   155      column-major
  1    320x240    no       1866 B     182   76800   154      column-major
  2    256x240    yes      3732 B     364   61440   129      column-major
  3    256x240    no       3732 B     364   61440   128      column-major
  4    256x192    yes       933 B      91   49152    99      row-major
  5    256x192    no        933 B      91   49152    98      row-major

Frame layout, all formats: audio + pad + [palette(512), even fmt only]
+ pixels. All sizes above are in bytes except sectors (512 B each);
frame_bytes = sectors * 512 exactly, asserted at import time below.

Audio: formats 0/1/2/3 are STEREO u8 (unsigned 8-bit PCM), samples
interleaved left-then-right (tools/ZXNextOS/.../interrupts-common.asm,
isr_ctc_stereo: "ld a,(hl) / inc l ; to odd address / out (0xf3),a ;
left dac B / ld a,(hl) / out (0xf9),a ; right dac C" - even offset =
left, odd = right). Formats 4/5 are MONO u8. "audio" above is bytes,
not samples: 1866 B stereo = 933 sample pairs; 3732 B stereo = 1866
pairs; 933 B mono = 933 samples.

Sample rate: derived here as (samples/frame) * (frames/sec), not taken
from playvid's own rounded "~15.6/31.1/23.3 kHz" labels (those are
tenths-precision documentation labels, VID_RATE*_X10 in nextdaad.inc,
not exact figures - confirmed by re-deriving them: 933 * 50/3 = 15550,
not 15600; 1866 * 50/3 = 31100 exactly; 933 * 25 = 23325, not 23330).
The exact per-format rate is what keeps a played-back frame's audio
covering precisely one frame's worth of real time.

Frame rate: 50/3 fps exactly (not 16.7) for the 240-line formats
(0/1/2/3), 25 fps exactly for the 192-line formats (4/5) - both taken
from the video_*.asm headers ("50/3 frame rate").

Pixel order: 256x192 (4/5) is row-major, confirmed by SP13 T2 (Layer 2
mode 0 addressing, "(row major order)" in video_256x192_m.asm's own
header). 320x240 and 256x240 (0/1/2/3) are column-major, confirmed by
SP13 T3 (Layer 2 mode 1, "(column major order)" in the video_*.asm
headers) - for each column x in 0..W-1, all W bytes for y in 0..H-1,
no gap bytes stored in the file (the 16-byte/column hardware stride gap
between real pixel data and the next column is a Layer 2 addressing
artifact the PLAYER skips; it is never present on disk).

Palette block (formats 0/2/4): 256 entries x 2 bytes, NR $44 write
order - byte0 = RRRGGGBB (3-3-2 posterized colour), byte1 bit0 = the
expanded 9th blue bit, bit7 (L2 priority) always 0. The 9th bit uses
the Next's own 8-bit-to-9-bit hardware expansion rule (docs/zx-next-
dev-guide-2022-07-15/chapter-next-palette.tex:176, "least significant
bit of blue is set to OR between B2 and B1"), applied to the 2-bit blue
field already baked into byte0 (byte1 = 1 iff byte0 & 3 != 0) - the
same rule tests/gen_vid_synth.py uses for its identity palette and the
interpreter's own vid_identity_palette (src/video.asm), generalized
here to arbitrary (non-identity) adaptive palette entries.

Non-palette formats (1/3/5): every pixel is posterized directly to its
own RRRGGGBB byte (3-3-2) - no palette block, no quantization pass.

Classification: playvid (and this project's interpreter) classify a
.VID file by total sector count, walking formats in priority order
0,1,2,3,4,5 (README.TXT: "classifying the video format solely based on
file size in priority order") and picking the first format whose
sector-per-frame count evenly divides the file's total sectors. This
encoder re-runs that exact walk after writing and refuses to emit a
file that would misclassify - see classify() and validate_output().
"""

import argparse
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

try:
    from PIL import Image, ImageChops
except ImportError:
    print("error: Pillow is required (pip install Pillow)", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FFMPEG = ROOT / "tools" / "ffmpeg" / "bin" / "ffmpeg.exe"

SILENCE_U8 = 128  # unsigned 8-bit PCM zero-crossing level

# Priority order for classification is the same as the format's own
# numeric index (0..5) - see README.TXT / classify() below.
FORMATS = {
    0: dict(width=320, height=240, palette=True,  stereo=True,
            spf=933,  pad=182, pixel_bytes=76800, sectors=155,
            column_major=True),
    1: dict(width=320, height=240, palette=False, stereo=True,
            spf=933,  pad=182, pixel_bytes=76800, sectors=154,
            column_major=True),
    2: dict(width=256, height=240, palette=True,  stereo=True,
            spf=1866, pad=364, pixel_bytes=61440, sectors=129,
            column_major=True),
    3: dict(width=256, height=240, palette=False, stereo=True,
            spf=1866, pad=364, pixel_bytes=61440, sectors=128,
            column_major=True),
    4: dict(width=256, height=192, palette=True,  spf=933, stereo=False,
            pad=91,   pixel_bytes=49152, sectors=99,
            column_major=False),
    5: dict(width=256, height=192, palette=False, spf=933, stereo=False,
            pad=91,   pixel_bytes=49152, sectors=98,
            column_major=False),
}

# 50/3 fps for the 240-line formats (0-3), 25 fps for the 192-line
# formats (4/5) - video_*.asm headers, "50/3 frame rate" /
# video_256x192_m*.asm "50/2 frame rate" (every 2nd VBI at 50Hz = 25fps).
for _fmt, _info in FORMATS.items():
    _info["fps"] = Fraction(50, 3) if _fmt < 4 else Fraction(25, 1)
    _info["channels"] = 2 if _info["stereo"] else 1
    _rate = Fraction(_info["spf"]) * _info["fps"]
    assert _rate.denominator == 1, (
        f"format {_fmt}: samples/frame * fps did not land on an exact "
        f"sample rate ({_rate}) - format table is wrong"
    )
    _info["rate"] = int(_rate)
    _info["audio_bytes"] = _info["spf"] * _info["channels"]
    _info["palette_bytes"] = 512 if _info["palette"] else 0
    _info["frame_bytes"] = (_info["audio_bytes"] + _info["pad"]
                             + _info["palette_bytes"] + _info["pixel_bytes"])
    assert _info["frame_bytes"] == _info["sectors"] * 512, (
        f"format {_fmt}: frame_bytes {_info['frame_bytes']} != "
        f"sectors*512 {_info['sectors'] * 512}"
    )


def fps_arg(fps: Fraction) -> str:
    """ffmpeg -r argument string for an exact rational frame rate."""
    if fps.denominator == 1:
        return str(fps.numerator)
    return f"{fps.numerator}/{fps.denominator}"


def classify(total_sectors: int) -> int:
    """Mirror playvid's own priority-order classifier (README.TXT):
    walk formats 0..5 in that order, return the first whose sector
    count evenly divides total_sectors. Returns -1 if none match
    (should not happen - format 5's own 98 always eventually divides
    a multiple of itself, i.e. at worst the walk terminates on the
    file's own true format)."""
    for fmt in range(6):
        if total_sectors % FORMATS[fmt]["sectors"] == 0:
            return fmt
    return -1


def run_ffmpeg(ffmpeg, args, what):
    cmd = [str(ffmpeg), "-y", "-v", "error"] + args
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode("utf-8", "replace"))
        raise SystemExit(f"error: ffmpeg failed extracting {what} "
                          f"(exit {proc.returncode})")
    return proc.stdout


def extract_video(ffmpeg, input_path, start, duration, info):
    args = []
    if start:
        args += ["-ss", start]
    args += ["-i", str(input_path)]
    if duration:
        args += ["-t", str(duration)]
    args += ["-vf", f"scale={info['width']}:{info['height']}",
              "-r", fps_arg(info["fps"]),
              "-pix_fmt", "rgb24", "-f", "rawvideo", "-an", "pipe:1"]
    raw = run_ffmpeg(ffmpeg, args, "video")
    frame_stride = info["width"] * info["height"] * 3
    nframes = len(raw) // frame_stride
    return raw[:nframes * frame_stride], nframes


def extract_audio(ffmpeg, input_path, start, duration, info):
    args = []
    if start:
        args += ["-ss", start]
    args += ["-i", str(input_path)]
    if duration:
        args += ["-t", str(duration)]
    args += ["-vn", "-ac", str(info["channels"]), "-ar", str(info["rate"]),
              "-f", "u8", "pipe:1"]
    return run_ffmpeg(ffmpeg, args, "audio")


def posterize_band(img):
    """Direct 3-3-2 posterize of an RGB image to a single 'L' band of
    RRRGGGBB bytes (formats 1/3/5, no palette). The three bit fields
    (bits 7-5 red, 4-2 green, 1-0 blue) never overlap, so addition is
    exactly bitwise OR - no clipping possible (max sum 0xE0+0x1C+0x03
    = 0xFF)."""
    r, g, b = img.split()
    r2 = r.point(lambda v: v & 0xE0)
    g2 = g.point(lambda v: (v >> 3) & 0x1C)
    b2 = b.point(lambda v: v >> 6)
    return ImageChops.add(ImageChops.add(r2, g2), b2)


def build_palette_block(pal_rgb):
    """256 entries x 2 bytes, NR $44 order. pal_rgb is a flat RGB list
    (from Image.getpalette(), padded to 768 entries by the caller)."""
    out = bytearray(512)
    for i in range(256):
        r, g, b = pal_rgb[i * 3], pal_rgb[i * 3 + 1], pal_rgb[i * 3 + 2]
        byte0 = (r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6)
        byte1 = 1 if (byte0 & 3) else 0  # 9th blue bit: OR(B1,B0)
        out[i * 2] = byte0
        out[i * 2 + 1] = byte1
    return bytes(out)


def encode_frame(rgb_frame, info, dither):
    """Returns (palette_block_or_empty, pixel_bytes) for one WxH RGB24
    frame, in the format's own pixel order."""
    img = Image.frombytes("RGB", (info["width"], info["height"]), rgb_frame)
    if info["palette"]:
        dmode = Image.Dither.FLOYDSTEINBERG if dither else Image.Dither.NONE
        idx_img = img.convert("P", palette=Image.Palette.ADAPTIVE,
                               colors=256, dither=dmode)
        pal = list(idx_img.getpalette() or [])
        pal += [0] * (768 - len(pal))
        pal_block = build_palette_block(pal)
    else:
        idx_img = posterize_band(img)
        pal_block = b""
    if info["column_major"]:
        pixels = idx_img.transpose(Image.Transpose.TRANSPOSE).tobytes()
    else:
        pixels = idx_img.tobytes()
    assert len(pixels) == info["pixel_bytes"]
    return pal_block, pixels


def blank_frame(info):
    """A filler frame used only to break a sector-count classification
    tie (see append_until_classifies) - silent audio, empty pad,
    all-zero palette/pixels. Never expected to be seen/heard for a
    normally sized clip."""
    audio = bytes([SILENCE_U8]) * info["audio_bytes"]
    pad = bytes(info["pad"])
    pal = bytes(info["palette_bytes"])
    pixels = bytes(info["pixel_bytes"])
    return audio + pad + pal + pixels


def append_until_classifies(out_path, fmt, info):
    """Priority-walk fixup (README.TXT's own documented escape hatch:
    "If your video is misclassified due to it being a multiple of the
    file size of another format, append a blank frame to the end").
    Appends whole blank frames until the file's total sector count no
    longer divides evenly by any EARLIER-priority format's sector
    count. Returns the number of blank frames appended."""
    appended = 0
    while True:
        total_bytes = out_path.stat().st_size
        assert total_bytes % 512 == 0
        total_sectors = total_bytes // 512
        collision = any(total_sectors % FORMATS[i]["sectors"] == 0
                         for i in range(fmt))
        if not collision:
            return appended
        with open(out_path, "ab") as f:
            f.write(blank_frame(info))
        appended += 1


def validate_output(out_path, fmt):
    total_bytes = out_path.stat().st_size
    if total_bytes % 512 != 0:
        raise SystemExit(f"error: output size {total_bytes} is not a "
                          f"whole number of sectors - refusing to ship")
    total_sectors = total_bytes // 512
    verdict = classify(total_sectors)
    if verdict != fmt:
        raise SystemExit(
            f"error: self-check failed - {out_path} ({total_bytes} B, "
            f"{total_sectors} sectors) classifies as format {verdict}, "
            f"not the requested format {fmt}. Refusing to ship a "
            f"misclassifying file."
        )
    return total_bytes, total_sectors


def main(argv):
    ap = argparse.ArgumentParser(
        description="Encode a video file into MakeVid/playvid .VID format "
                    "(open, spec-compliant - see tests/videnc-README.md).")
    ap.add_argument("input", help="any video file ffmpeg can read")
    ap.add_argument("output", help="destination .VID file")
    ap.add_argument("--format", type=int, required=True, choices=range(6),
                     help="target format 0-5 (see module docstring table)")
    ap.add_argument("--start", help="ffmpeg -ss start time (HH:MM:SS)")
    ap.add_argument("--duration", help="clip duration in seconds")
    ap.add_argument("--dither", action="store_true",
                     help="Floyd-Steinberg dither the palette formats "
                          "(default: no dither, matching tools/png2nx.py)")
    ap.add_argument("--ffmpeg", default=str(DEFAULT_FFMPEG),
                     help=f"ffmpeg binary (default: {DEFAULT_FFMPEG})")
    args = ap.parse_args(argv[1:])

    ffmpeg = Path(args.ffmpeg)
    if not ffmpeg.exists():
        raise SystemExit(f"error: ffmpeg not found at {ffmpeg}")

    info = FORMATS[args.format]
    input_path = Path(args.input)
    if not input_path.exists():
        raise SystemExit(f"error: input not found: {input_path}")
    out_path = Path(args.output)

    print(f"format {args.format}: {info['width']}x{info['height']}, "
          f"{'palette' if info['palette'] else 'no-palette'}, "
          f"{'stereo' if info['stereo'] else 'mono'}, "
          f"{info['rate']} Hz, {fps_arg(info['fps'])} fps, "
          f"{info['frame_bytes']} B/frame ({info['sectors']} sectors)")

    print("extracting video frames...")
    video_bytes, nframes = extract_video(ffmpeg, input_path, args.start,
                                          args.duration, info)
    if nframes == 0:
        raise SystemExit("error: no frames decoded - check input/"
                          "--start/--duration")
    print(f"  {nframes} frames decoded")

    print("extracting audio...")
    audio_bytes = extract_audio(ffmpeg, input_path, args.start,
                                 args.duration, info)
    needed = nframes * info["audio_bytes"]
    if len(audio_bytes) < needed:
        short = needed - len(audio_bytes)
        print(f"  source audio shorter than video by {short} B - "
              f"padding with silence")
        audio_bytes = audio_bytes + bytes([SILENCE_U8]) * short
    elif len(audio_bytes) > needed:
        audio_bytes = audio_bytes[:needed]
    print(f"  {len(audio_bytes)} B ({info['channels']}ch u8 @ "
          f"{info['rate']} Hz)")

    frame_stride = info["width"] * info["height"] * 3
    print(f"encoding {nframes} frames...")
    report_every = max(1, nframes // 10)
    with open(out_path, "wb") as f:
        for n in range(nframes):
            rgb_frame = video_bytes[n * frame_stride:(n + 1) * frame_stride]
            audio_slice = audio_bytes[n * info["audio_bytes"]:
                                       (n + 1) * info["audio_bytes"]]
            pal_block, pixels = encode_frame(rgb_frame, info, args.dither)
            frame_out = audio_slice + bytes(info["pad"]) + pal_block + pixels
            assert len(frame_out) == info["frame_bytes"]
            f.write(frame_out)
            if (n + 1) % report_every == 0 or n + 1 == nframes:
                print(f"  {n + 1}/{nframes} frames")

    appended = append_until_classifies(out_path, args.format, info)
    if appended:
        print(f"  appended {appended} blank frame(s) to break a "
              f"classification collision with an earlier-priority format")

    total_bytes, total_sectors = validate_output(out_path, args.format)
    print(f"wrote {out_path}: {total_bytes} B, {total_sectors} sectors, "
          f"classifies as format {args.format} - OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
