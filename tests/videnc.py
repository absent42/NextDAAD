#!/usr/bin/env python3
"""
tests/videnc.py - encoder for NextDAAD's native NXV video format (SP14a
T4), with the original six-format MakeVid/playvid encoder kept behind
--legacy for anyone who still needs a file for playvid itself.

Sync convention: authoring-kit/lib/videnc.py is a kit copy of this
file - its ENCODING LOGIC must stay identical to this one; only its
docstring and --help text may differ. Port any logic fix to both (the
authoring-kit copy's own NXV sync is T5's job, not this task's - do not
touch it here).

NXV (default output): docs/superpowers/specs/2026-07-21-sp14a-native-
video-design.md is the format authority. ONE parameterized container,
every section an exact multiple of 512-byte SD blocks - REPLACES the old
sizeless six-format classifier entirely (a real header, not a divisor
walk). See nextdaad.inc's own NXV_OFF_* header-layout comment for the
exact byte offsets this encoder writes (kept identical, on purpose, so
one comment block is the single source of truth for both sides).

Five shipped profiles (the spec's own matrix):
  N0 "cinema"        320x256 mode-1  12.5 fps   full-bleed
  N1 "classic"        256x192 mode-0  20   fps   full-bleed
  N2 "widescreen"      256x144 mode-0  25   fps   letterboxed (mode-0,
                                                    trivially - no gap)
  N3 "widescreen XL"   320x192 mode-1  16.667 fps  letterboxed (mode-1
                                                    column gap)
  N4 "epic"            320x120 mode-1  25   fps   letterboxed (mode-1
                                                    column gap, anamorphic)

--profile auto picks the shipped profile whose own pixel aspect ratio
(width/height, square-pixel assumption) is closest to the source's -
a simple, disclosed heuristic (not a physical-display-aspect model);
pass an explicit --profile if the source's intended framing needs a
specific shape.

Audio: full rate always (no decimation, unlike the old MakeVid-era
downsampled formats) - two supported rates, chosen so the CTC time
constant divides cleanly on every video mode (src/video.asm's own
vidCtcTcNxvStereo/Mono tables, T1's derivation method): stereo
15625 Hz, mono 23325 Hz (nextdaad.inc's NXV_RATE_STEREO/MONO). Samples/
frame = round(rate/fps) - not always an exact integer division for
every profile's fps (N1's 20fps and N3's 50/3fps in particular), so the
achieved rate drifts a few Hz from the nominal target; the drift is
disclosed here and in the task report, and is two orders of magnitude
smaller than this project's own already-accepted CTC-quantization error
class. audioBytesReal = samples*channels (the played length);
audioBytesPad = audioBytesReal rounded up to a 512-byte block multiple
(the wire read size - the pad bytes are silent filler, never played).

Pixel order: mode-1 (N0/N3/N4) is column-major (Layer 2 mode 1
addressing); mode-0 (N1/N2) is row-major. Column-major output uses
Pillow's own transpose, which already yields exactly `height` real
bytes per column with NO stride padding - precisely what the player's
flat/gap blits expect on the wire (nextdaad.inc's own header: "the bars
cost ZERO wire bytes - the format streams content lines only").

Cropping: the source's own pixel dimensions are always probed (ffmpeg
-i stderr, same regex --profile auto uses) and compared against the
target profile's aspect ratio (width/height, square-pixel assumption).
If they differ, the source is CENTER-CROPPED to the profile's exact
aspect before scaling - never stretched/squashed - so every shipped
profile presents undistorted content regardless of source aspect. The
crop always removes the SMALLER dimension's excess: source wider than
the profile (src aspect > profile aspect) crops the sides (equal margins
left/right, full source height kept); source narrower/taller than the
profile crops top/bottom (equal margins top/bottom, full source width
kept). An exact aspect match (e.g. a 4:3 source for N1, or a 16:9 source
for N2) performs no crop at all. See compute_center_crop's own docstring
for the exact arithmetic.

Palette block (palette-flag files): 256 entries x 2 bytes, NR $44 write
order - identical construction to the legacy encoder's own (see
build_palette_block, shared by both paths).

Requires: Python 3, Pillow. An ffmpeg binary is required at run time
(default: the project's own tools\\ffmpeg\\bin\\ffmpeg.exe, override
with --ffmpeg).
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

# ---------------------------------------------------------------------
# NXV header layout (nextdaad.inc's own NXV_OFF_* comment is the
# authority - offsets/sizes here MUST match it exactly).
# ---------------------------------------------------------------------
NXV_MAGIC = b"NXVID"
NXV_VERSION = 1
NXV_OFF_MAGIC = 0
NXV_OFF_VERSION = 5
NXV_OFF_SHAPE = 6
NXV_OFF_WIDTH = 7
NXV_OFF_HEIGHT = 9
NXV_OFF_FPSX10 = 11
NXV_OFF_ACHAN = 13
NXV_OFF_ARATE = 14
NXV_OFF_ABYTES_PAD = 16
NXV_OFF_ABYTES_REAL = 18
NXV_OFF_PALFLAG = 20
NXV_OFF_FRAMES = 21
NXV_OFF_PIXBLK = 24
NXV_HEADER_SIZE = 512

NXV_SHAPE_MODE1 = 0   # 320-wide, Layer 2 mode 1, column-major
NXV_SHAPE_MODE0 = 1   # 256-wide, Layer 2 mode 0, row-major
NXV_RATE_STEREO = 15625
NXV_RATE_MONO = 23325

NXV_PROFILES = {
    "n0": dict(shape=NXV_SHAPE_MODE1, width=320, height=256, fps=Fraction(25, 2)),
    "n1": dict(shape=NXV_SHAPE_MODE0, width=256, height=192, fps=Fraction(20, 1)),
    "n2": dict(shape=NXV_SHAPE_MODE0, width=256, height=144, fps=Fraction(25, 1)),
    "n3": dict(shape=NXV_SHAPE_MODE1, width=320, height=192, fps=Fraction(50, 3)),
    "n4": dict(shape=NXV_SHAPE_MODE1, width=320, height=120, fps=Fraction(25, 1)),
}
for _name, _p in NXV_PROFILES.items():
    _p["column_major"] = (_p["shape"] == NXV_SHAPE_MODE1)
    _p["aspect"] = Fraction(_p["width"], _p["height"])


def nxv_audio_layout(fps: Fraction, channels: int):
    """Returns (rate, samples_per_frame, real_bytes, padded_bytes) for a
    full-rate NXV audio stream at the given fps/channel count. samples
    = round(rate/fps) - see this module's own docstring for the achieved
    -rate drift this rounding implies on some profile/channel pairs."""
    rate = NXV_RATE_STEREO if channels == 2 else NXV_RATE_MONO
    exact = Fraction(rate) / fps
    samples = int(exact + Fraction(1, 2))  # round-half-up, always positive
    real = samples * channels
    padded = ((real + 511) // 512) * 512
    return rate, samples, real, padded


def nxv_pick_profile(width: int, height: int) -> str:
    """--profile auto: nearest pixel-aspect match (square-pixel
    assumption) among the five shipped profiles - see this module's own
    docstring for the disclosed limits of this heuristic."""
    src_aspect = Fraction(width, height)
    best, best_diff = None, None
    for name, p in NXV_PROFILES.items():
        diff = abs(p["aspect"] - src_aspect)
        if best_diff is None or diff < best_diff:
            best, best_diff = name, diff
    return best


def nxv_build_header(profile: dict, channels: int, rate: int, abytes_pad: int,
                      abytes_real: int, palette: bool, frame_count: int,
                      pixblocks: int) -> bytes:
    hdr = bytearray(NXV_HEADER_SIZE)
    hdr[NXV_OFF_MAGIC:NXV_OFF_MAGIC + 5] = NXV_MAGIC
    hdr[NXV_OFF_VERSION] = NXV_VERSION
    hdr[NXV_OFF_SHAPE] = profile["shape"]
    hdr[NXV_OFF_WIDTH:NXV_OFF_WIDTH + 2] = profile["width"].to_bytes(2, "little")
    hdr[NXV_OFF_HEIGHT:NXV_OFF_HEIGHT + 2] = profile["height"].to_bytes(2, "little")
    fps_x10 = round(profile["fps"] * 10)
    hdr[NXV_OFF_FPSX10:NXV_OFF_FPSX10 + 2] = fps_x10.to_bytes(2, "little")
    hdr[NXV_OFF_ACHAN] = channels
    hdr[NXV_OFF_ARATE:NXV_OFF_ARATE + 2] = rate.to_bytes(2, "little")
    hdr[NXV_OFF_ABYTES_PAD:NXV_OFF_ABYTES_PAD + 2] = abytes_pad.to_bytes(2, "little")
    hdr[NXV_OFF_ABYTES_REAL:NXV_OFF_ABYTES_REAL + 2] = abytes_real.to_bytes(2, "little")
    hdr[NXV_OFF_PALFLAG] = 1 if palette else 0
    hdr[NXV_OFF_FRAMES:NXV_OFF_FRAMES + 3] = frame_count.to_bytes(3, "little")
    hdr[NXV_OFF_PIXBLK:NXV_OFF_PIXBLK + 2] = pixblocks.to_bytes(2, "little")
    return bytes(hdr)


# ---------------------------------------------------------------------
# Legacy MakeVid/playvid format table (six formats 0-5) - unsupported by
# NextDAAD's own player (SP14a T4 scrapped MakeVid compatibility), kept
# only for anyone who needs a file for playvid itself.
# ---------------------------------------------------------------------
LEGACY_FORMATS = {
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
for _fmt, _info in LEGACY_FORMATS.items():
    _info["fps"] = Fraction(50, 3) if _fmt < 4 else Fraction(25, 1)
    _info["channels"] = 2 if _info["stereo"] else 1
    _rate = Fraction(_info["spf"]) * _info["fps"]
    assert _rate.denominator == 1, (
        f"legacy format {_fmt}: samples/frame * fps did not land on an "
        f"exact sample rate ({_rate}) - format table is wrong"
    )
    _info["rate"] = int(_rate)
    _info["audio_bytes"] = _info["spf"] * _info["channels"]
    _info["palette_bytes"] = 512 if _info["palette"] else 0
    _info["frame_bytes"] = (_info["audio_bytes"] + _info["pad"]
                             + _info["palette_bytes"] + _info["pixel_bytes"])
    assert _info["frame_bytes"] == _info["sectors"] * 512, (
        f"legacy format {_fmt}: frame_bytes {_info['frame_bytes']} != "
        f"sectors*512 {_info['sectors'] * 512}"
    )


def fps_arg(fps: Fraction) -> str:
    """ffmpeg -r argument string for an exact rational frame rate."""
    if fps.denominator == 1:
        return str(fps.numerator)
    return f"{fps.numerator}/{fps.denominator}"


def legacy_classify(total_sectors: int) -> int:
    """Mirrors playvid's own priority-order classifier (README.TXT):
    walk formats 0..5 in that order, return the first whose sector
    count evenly divides total_sectors. Returns -1 if none match."""
    for fmt in range(6):
        if total_sectors % LEGACY_FORMATS[fmt]["sectors"] == 0:
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


def probe_dimensions(ffmpeg, input_path):
    """Returns (width, height) of the source's own first video stream,
    read from ffmpeg's own stderr banner (no ffprobe dependency - see
    encode_nxv's --profile auto comment, this is the same probe, shared
    so the center-crop math below never needs a second one)."""
    probe = subprocess.run(
        [str(ffmpeg), "-i", str(input_path)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stderr = probe.stderr.decode("utf-8", "replace")
    import re
    m = re.search(r",\s*(\d{2,5})x(\d{2,5})[,\s]", stderr)
    if not m:
        raise SystemExit(
            "error: could not detect the source's own dimensions from "
            "ffmpeg's own output")
    return int(m.group(1)), int(m.group(2))


def compute_center_crop(src_w, src_h, target_w, target_h):
    """Returns (crop_w, crop_h, crop_x, crop_y) that center-crops a
    src_w x src_h source down to the target_w/target_h aspect ratio
    (square-pixel assumption), or None if the aspect already matches
    exactly (no crop needed). Never upsamples/stretches - only trims the
    dimension that makes the source relatively too wide or too tall:
    src wider than target (src_aspect > target_aspect) crops the sides
    (crop_w < src_w, crop_h = src_h); src narrower/taller than target
    crops top/bottom (crop_h < src_h, crop_w = src_w). The result is
    then a straight aspect-preserving scale to target_w x target_h -
    see extract_video's own caller."""
    src_aspect = Fraction(src_w, src_h)
    target_aspect = Fraction(target_w, target_h)
    if src_aspect == target_aspect:
        return None
    if src_aspect > target_aspect:
        crop_h = src_h
        crop_w = round(Fraction(src_h) * target_aspect)
        crop_w -= crop_w % 2
    else:
        crop_w = src_w
        crop_h = round(Fraction(src_w) / target_aspect)
        crop_h -= crop_h % 2
    crop_x = (src_w - crop_w) // 2
    crop_y = (src_h - crop_h) // 2
    return crop_w, crop_h, crop_x, crop_y


def extract_video(ffmpeg, input_path, start, duration, width, height, fps,
                   crop=None):
    args = []
    if start:
        args += ["-ss", start]
    args += ["-i", str(input_path)]
    if duration:
        args += ["-t", str(duration)]
    vf = []
    if crop:
        crop_w, crop_h, crop_x, crop_y = crop
        vf.append(f"crop={crop_w}:{crop_h}:{crop_x}:{crop_y}")
    vf.append(f"scale={width}:{height}")
    args += ["-vf", ",".join(vf),
              "-r", fps_arg(fps),
              "-pix_fmt", "rgb24", "-f", "rawvideo", "-an", "pipe:1"]
    raw = run_ffmpeg(ffmpeg, args, "video")
    frame_stride = width * height * 3
    nframes = len(raw) // frame_stride
    return raw[:nframes * frame_stride], nframes


def extract_audio(ffmpeg, input_path, start, duration, channels, rate):
    args = []
    if start:
        args += ["-ss", start]
    args += ["-i", str(input_path)]
    if duration:
        args += ["-t", str(duration)]
    args += ["-vn", "-ac", str(channels), "-ar", str(rate),
              "-f", "u8", "pipe:1"]
    return run_ffmpeg(ffmpeg, args, "audio")


def posterize_band(img):
    """Direct 3-3-2 posterize of an RGB image to a single 'L' band of
    RRRGGGBB bytes (no-palette-flag output), the three bit fields (bits
    7-5 red, 4-2 green, 1-0 blue) never overlapping, so addition is
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


def encode_frame(rgb_frame, width, height, column_major, palette, dither):
    """Returns (palette_block_or_empty, pixel_bytes) for one WxH RGB24
    frame. Column-major output (Pillow's own transpose) yields exactly
    `height` real bytes per column with no stride padding - shared by
    both the NXV and legacy encode paths."""
    img = Image.frombytes("RGB", (width, height), rgb_frame)
    if palette:
        dmode = Image.Dither.FLOYDSTEINBERG if dither else Image.Dither.NONE
        idx_img = img.convert("P", palette=Image.Palette.ADAPTIVE,
                               colors=256, dither=dmode)
        pal = list(idx_img.getpalette() or [])
        pal += [0] * (768 - len(pal))
        pal_block = build_palette_block(pal)
    else:
        idx_img = posterize_band(img)
        pal_block = b""
    if column_major:
        pixels = idx_img.transpose(Image.Transpose.TRANSPOSE).tobytes()
    else:
        pixels = idx_img.tobytes()
    assert len(pixels) == width * height
    return pal_block, pixels


def blank_frame_legacy(info):
    """A filler frame used only to break a legacy sector-count
    classification tie (README.TXT's own documented escape hatch)."""
    audio = bytes([SILENCE_U8]) * info["audio_bytes"]
    pad = bytes(info["pad"])
    pal = bytes(info["palette_bytes"])
    pixels = bytes(info["pixel_bytes"])
    return audio + pad + pal + pixels


def append_until_classifies(out_path, fmt, info):
    """Legacy-only: appends whole blank frames until the file's total
    sector count no longer divides evenly by any EARLIER-priority
    format's sector count. Returns the number of blank frames appended.
    NXV needs no equivalent - the header makes every file self-
    describing, killing the whole classification-collision hazard."""
    appended = 0
    while True:
        total_bytes = out_path.stat().st_size
        assert total_bytes % 512 == 0
        total_sectors = total_bytes // 512
        collision = any(total_sectors % LEGACY_FORMATS[i]["sectors"] == 0
                         for i in range(fmt))
        if not collision:
            return appended
        with open(out_path, "ab") as f:
            f.write(blank_frame_legacy(info))
        appended += 1


def validate_legacy_output(out_path, fmt):
    total_bytes = out_path.stat().st_size
    if total_bytes % 512 != 0:
        raise SystemExit(f"error: output size {total_bytes} is not a "
                          f"whole number of sectors - refusing to ship")
    total_sectors = total_bytes // 512
    verdict = legacy_classify(total_sectors)
    if verdict != fmt:
        raise SystemExit(
            f"error: self-check failed - {out_path} ({total_bytes} B, "
            f"{total_sectors} sectors) classifies as format {verdict}, "
            f"not the requested format {fmt}. Refusing to ship a "
            f"misclassifying file."
        )
    return total_bytes, total_sectors


def encode_nxv(args):
    profile_name = args.profile
    input_path = Path(args.input)
    if not input_path.exists():
        raise SystemExit(f"error: input not found: {input_path}")
    out_path = Path(args.output)

    channels = 1 if args.mono else 2
    palette = not args.no_palette

    ffmpeg = Path(args.ffmpeg)
    if not ffmpeg.exists():
        raise SystemExit(f"error: ffmpeg not found at {ffmpeg}")

    # Source dimensions are always probed now - --profile auto's own pick
    # needs them, and so does the center-crop computed below regardless
    # of profile (an explicit --profile still gets an undistorted crop,
    # not a stretch, when the source aspect does not already match).
    src_w, src_h = probe_dimensions(ffmpeg, input_path)

    if profile_name == "auto":
        profile_name = nxv_pick_profile(src_w, src_h)
        print(f"--profile auto: source {src_w}x{src_h} -> {profile_name}")

    if profile_name not in NXV_PROFILES:
        raise SystemExit(f"error: unknown profile {profile_name!r} - "
                          f"choose one of {sorted(NXV_PROFILES)} or auto")
    profile = NXV_PROFILES[profile_name]
    width, height, fps = profile["width"], profile["height"], profile["fps"]
    column_major = profile["column_major"]

    crop = compute_center_crop(src_w, src_h, width, height)
    if crop:
        crop_w, crop_h, crop_x, crop_y = crop
        print(f"  source {src_w}x{src_h} -> center-crop {crop_w}x{crop_h} "
              f"+{crop_x}+{crop_y} -> scale {width}x{height} (undistorted)")
    else:
        print(f"  source {src_w}x{src_h} aspect already matches "
              f"{profile_name} - no crop, straight scale to {width}x{height}")

    pixel_bytes = width * height
    if pixel_bytes % 512 != 0:
        raise SystemExit(
            f"error: profile {profile_name} pixel size {pixel_bytes} is "
            f"not a 512-byte multiple - format table is wrong")
    pixblocks = pixel_bytes // 512

    rate, samples_per_frame, abytes_real, abytes_pad = nxv_audio_layout(
        fps, channels)

    print(f"profile {profile_name}: {width}x{height} "
          f"{'mode-1' if profile['shape'] == NXV_SHAPE_MODE1 else 'mode-0'}, "
          f"{'palette' if palette else 'no-palette'}, "
          f"{'stereo' if channels == 2 else 'mono'} {rate} Hz, "
          f"{fps_arg(fps)} fps, pixels {pixel_bytes} B ({pixblocks} blocks), "
          f"audio {abytes_real} B real / {abytes_pad} B padded")

    print("extracting video frames...")
    video_bytes, nframes = extract_video(ffmpeg, input_path, args.start,
                                          args.duration, width, height, fps,
                                          crop=crop)
    if nframes == 0:
        raise SystemExit("error: no frames decoded - check input/"
                          "--start/--duration")
    print(f"  {nframes} frames decoded")
    if nframes >= (1 << 24):
        raise SystemExit("error: frame count exceeds the header's 24-bit "
                          "field - clip is absurdly long, trim it first")

    print("extracting audio...")
    audio_bytes = extract_audio(ffmpeg, input_path, args.start,
                                 args.duration, channels, rate)
    needed = nframes * abytes_real
    if len(audio_bytes) < needed:
        short = needed - len(audio_bytes)
        print(f"  source audio shorter than video by {short} B - "
              f"padding with silence")
        audio_bytes = audio_bytes + bytes([SILENCE_U8]) * short
    elif len(audio_bytes) > needed:
        audio_bytes = audio_bytes[:needed]
    print(f"  {len(audio_bytes)} B ({channels}ch u8 @ {rate} Hz)")

    frame_stride = width * height * 3
    audio_frame_pad = bytes([SILENCE_U8]) * (abytes_pad - abytes_real)

    print(f"encoding {nframes} frames...")
    report_every = max(1, nframes // 10)
    with open(out_path, "wb") as f:
        f.write(nxv_build_header(profile, channels, rate, abytes_pad,
                                  abytes_real, palette, nframes, pixblocks))
        for n in range(nframes):
            rgb_frame = video_bytes[n * frame_stride:(n + 1) * frame_stride]
            audio_slice = audio_bytes[n * abytes_real:(n + 1) * abytes_real]
            pal_block, pixels = encode_frame(rgb_frame, width, height,
                                              column_major, palette,
                                              args.dither)
            frame_out = audio_slice + audio_frame_pad + pal_block + pixels
            expected = abytes_pad + (512 if palette else 0) + pixel_bytes
            assert len(frame_out) == expected
            f.write(frame_out)
            if (n + 1) % report_every == 0 or n + 1 == nframes:
                print(f"  {n + 1}/{nframes} frames")

    total_bytes = out_path.stat().st_size
    if total_bytes % 512 != 0:
        raise SystemExit(f"error: internal error - output size "
                          f"{total_bytes} is not a 512-byte multiple")
    print(f"wrote {out_path}: {total_bytes} B, {total_bytes // 512} "
          f"sectors, profile {profile_name}, {nframes} frames - OK")
    return 0


def encode_legacy(args):
    if args.format is None:
        raise SystemExit("error: --legacy requires --format 0-5")
    info = LEGACY_FORMATS[args.format]
    input_path = Path(args.input)
    if not input_path.exists():
        raise SystemExit(f"error: input not found: {input_path}")
    out_path = Path(args.output)
    ffmpeg = Path(args.ffmpeg)
    if not ffmpeg.exists():
        raise SystemExit(f"error: ffmpeg not found at {ffmpeg}")

    print(f"LEGACY format {args.format} (unsupported by NextDAAD's own "
          f"player - MakeVid compatibility was scrapped, SP14a T4): "
          f"{info['width']}x{info['height']}, "
          f"{'palette' if info['palette'] else 'no-palette'}, "
          f"{'stereo' if info['stereo'] else 'mono'}, "
          f"{info['rate']} Hz, {fps_arg(info['fps'])} fps, "
          f"{info['frame_bytes']} B/frame ({info['sectors']} sectors)")

    print("extracting video frames...")
    video_bytes, nframes = extract_video(ffmpeg, input_path, args.start,
                                          args.duration, info["width"],
                                          info["height"], info["fps"])
    if nframes == 0:
        raise SystemExit("error: no frames decoded - check input/"
                          "--start/--duration")
    print(f"  {nframes} frames decoded")

    print("extracting audio...")
    audio_bytes = extract_audio(ffmpeg, input_path, args.start,
                                 args.duration, info["channels"],
                                 info["rate"])
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
            pal_block, pixels = encode_frame(
                rgb_frame, info["width"], info["height"],
                info["column_major"], info["palette"], args.dither)
            frame_out = audio_slice + bytes(info["pad"]) + pal_block + pixels
            assert len(frame_out) == info["frame_bytes"]
            f.write(frame_out)
            if (n + 1) % report_every == 0 or n + 1 == nframes:
                print(f"  {n + 1}/{nframes} frames")

    appended = append_until_classifies(out_path, args.format, info)
    if appended:
        print(f"  appended {appended} blank frame(s) to break a "
              f"classification collision with an earlier-priority format")

    total_bytes, total_sectors = validate_legacy_output(out_path, args.format)
    print(f"wrote {out_path}: {total_bytes} B, {total_sectors} sectors, "
          f"classifies as legacy format {args.format} - OK "
          f"(unsupported by NextDAAD's own player)")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(
        description="Encode a video file into NextDAAD's native NXV "
                    "format (default), or a legacy MakeVid/playvid "
                    "format with --legacy (see tests/videnc-README.md).")
    ap.add_argument("input", help="any video file ffmpeg can read")
    ap.add_argument("output", help="destination video file")
    ap.add_argument("--profile", default="auto", choices=list(NXV_PROFILES) + ["auto"],
                     help="NXV profile n0-n4, or auto (nearest pixel-"
                          "aspect match - see module docstring). "
                          "Ignored with --legacy.")
    ap.add_argument("--mono", action="store_true",
                     help="NXV: mono audio (23325 Hz) instead of the "
                          "default stereo (15625 Hz)")
    ap.add_argument("--no-palette", action="store_true",
                     help="NXV: RGB332-direct pixels (no per-frame "
                          "palette block) instead of the default "
                          "adaptive per-frame palette")
    ap.add_argument("--legacy", action="store_true",
                     help="encode a legacy MakeVid/playvid format "
                          "instead of NXV - unsupported by NextDAAD's "
                          "own player, for playvid compatibility only")
    ap.add_argument("--format", type=int, choices=range(6),
                     help="--legacy only: target format 0-5")
    ap.add_argument("--start", help="ffmpeg -ss start time (HH:MM:SS)")
    ap.add_argument("--duration", help="clip duration in seconds")
    ap.add_argument("--dither", action="store_true",
                     help="Floyd-Steinberg dither the palette formats "
                          "(default: no dither, matching tools/png2nx.py)")
    ap.add_argument("--ffmpeg", default=str(DEFAULT_FFMPEG),
                     help=f"ffmpeg binary (default: {DEFAULT_FFMPEG})")
    args = ap.parse_args(argv[1:])

    if args.legacy:
        return encode_legacy(args)
    return encode_nxv(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
