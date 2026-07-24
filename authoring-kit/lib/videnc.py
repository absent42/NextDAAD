#!/usr/bin/env python3
"""
authoring-kit/lib/videnc.py - CLI for NextDAAD's native NXV video
format. NXV v2 (SP15 T1) is the only output now - the v1 fixed-profile
container (five shipped profiles n0-n4) was replaced wholesale (owner
decision, 2026-07-24): v1 files are no longer produced or read by this
tool. docs/superpowers/plans/2026-07-23-sp15-nxv2.md's "Format
reference" section is the format authority; authoring-kit/lib/
nxv2enc.py and nxv2dec.py are the encoder pipeline and reference
decoder - this file is a thin CLI shell around nxv2enc.encode().

This is the ONE canonical copy (owner consolidation, 2026-07-23). It
ships in the authoring kit and the repo's own test harness consumes it
from here (build-tests.ps1 -Vid), the same pattern as lib/fontconv.ps1.
The default ffmpeg path resolves relative to this file (authoring-kit/
tools/ffmpeg/); repo callers pass --ffmpeg tools/ffmpeg/bin/ffmpeg.exe
explicitly.

Shape (replaces v1's five fixed profiles): --shape picks one of five
presets (full/16:9/scope/classic/classic-wide, see nxv2enc.PRESETS) or
an explicit WIDTHxHEIGHT (width must be 256 or 320 - the only two
Layer 2 shapes); --aspect derives a FREE height for a given width from
a target displayed aspect ratio (e.g. --width 320 --aspect 2.35 for
true cinema scope), correcting for Layer 2 mode-1's non-square pixels
(nxv2enc.derive_free_height's own docstring has the exact math). --fps
is independent of shape (the v1 profiles baked one fixed fps per
profile; v2 does not) - default 25.

Audio: full rate always, same two rates as v1 (chosen so the CTC time
constant divides cleanly on every video mode): stereo 15625 Hz, mono
23325 Hz (nxv2enc.RATE_STEREO/RATE_MONO). Samples/frame = round(rate/
fps) - the achieved rate drifts a few Hz from nominal on some fps
values, disclosed here as it was for v1.

Cropping: the source's own pixel dimensions are always probed (ffmpeg
-i stderr) and compared against the target shape's aspect ratio
(width/height, square-pixel assumption). If they differ, the source is
CENTER-CROPPED to the shape's exact aspect before scaling - never
stretched/squashed. See compute_center_crop's own docstring for the
exact arithmetic.

Quality: NXV v2 is a content-triggered-keyframe, dual-budget (bytes +
modeled decode-T) delta codec - encode time is the main quality lever
(nxv2enc.TMODEL_COEFFS is model-not-silicon; Task 2's bench replaces
it before the format freezes). --report writes the BuildReport
(mean/worst PSNR, keyframe count, bytes, binding-budget histogram) as
JSON next to the output file.

Requires: Python 3, Pillow, numpy. An ffmpeg binary is required at run
time (default: the project's own tools\\ffmpeg\\bin\\ffmpeg.exe,
override with --ffmpeg).
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


def fps_arg(fps: Fraction) -> str:
    """ffmpeg -r argument string for an exact rational frame rate."""
    if fps.denominator == 1:
        return str(fps.numerator)
    return f"{fps.numerator}/{fps.denominator}"


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
    read from ffmpeg's own stderr banner (no ffprobe dependency - the
    same probe the center-crop math below and nxv2enc's --shape auto
    picker both need, shared so there is only one implementation)."""
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


def main(argv):
    import nxv2enc

    ap = argparse.ArgumentParser(
        description="Encode a video file into NextDAAD's native NXV v2 "
                    "format (see lib/videnc-README.md).")
    ap.add_argument("input", help="any video file ffmpeg can read")
    ap.add_argument("output", help="destination .VID file")
    ap.add_argument("--shape", default=None,
                     help="shape preset (full/16:9/scope/classic/"
                          "classic-wide, default: full) or an explicit "
                          "WIDTHxHEIGHT (width must be 256 or 320)")
    ap.add_argument("--width", type=int, choices=(256, 320), default=None,
                     help="Layer 2 width for --aspect free-height "
                          "derivation (256 or 320); ignored if --shape "
                          "is given")
    ap.add_argument("--aspect", type=float, default=None,
                     help="derive a free height for --width from a "
                          "target displayed aspect ratio (w/h, e.g. "
                          "2.35 for cinema scope) - see nxv2enc."
                          "derive_free_height; overrides --shape")
    ap.add_argument("--fps", type=float, default=25.0,
                     help="frames per second (default: 25)")
    ap.add_argument("--mono", action="store_true",
                     help="mono audio (23325 Hz) instead of the "
                          "default stereo (15625 Hz)")
    ap.add_argument("--dither", action="store_true",
                     help="Floyd-Steinberg dither the palette "
                          "(default: no dither, matching tools/png2nx.py)")
    ap.add_argument("--start", help="ffmpeg -ss start time (HH:MM:SS)")
    ap.add_argument("--duration", help="clip duration in seconds")
    ap.add_argument("--report", help="write the BuildReport as JSON to "
                                      "this path (default: none)")
    ap.add_argument("--ffmpeg", default=str(DEFAULT_FFMPEG),
                     help=f"ffmpeg binary (default: {DEFAULT_FFMPEG})")
    args = ap.parse_args(argv[1:])

    input_path = Path(args.input)
    if not input_path.exists():
        raise SystemExit(f"error: input not found: {input_path}")
    ffmpeg = Path(args.ffmpeg)
    if not ffmpeg.exists():
        raise SystemExit(f"error: ffmpeg not found at {ffmpeg}")

    if args.aspect is not None:
        width = args.width or 320
        height = nxv2enc.derive_free_height(width, args.aspect)
        shape = (width, height)
        print(f"--aspect {args.aspect}: width {width} -> free height {height}")
    elif args.shape is not None and "x" in args.shape.lower() and args.shape not in nxv2enc.PRESETS:
        w_str, h_str = args.shape.lower().split("x", 1)
        shape = (int(w_str), int(h_str))
    else:
        shape = args.shape   # a preset name, or None (default: "full")

    width, height = nxv2enc.resolve_shape(shape)

    src_w, src_h = probe_dimensions(ffmpeg, input_path)
    crop = compute_center_crop(src_w, src_h, width, height)
    if crop:
        crop_w, crop_h, crop_x, crop_y = crop
        print(f"  source {src_w}x{src_h} -> center-crop {crop_w}x{crop_h} "
              f"+{crop_x}+{crop_y} -> scale {width}x{height} (undistorted)")
    else:
        print(f"  source {src_w}x{src_h} aspect already matches "
              f"{width}x{height} - no crop, straight scale")

    print(f"encoding {width}x{height} @ {args.fps} fps "
          f"({'mono' if args.mono else 'stereo'}) -> {args.output}")
    report = nxv2enc.encode(
        str(input_path), args.output, shape=(width, height), fps=args.fps,
        quality_profile="max", report_path=args.report,
        start=args.start, duration=args.duration, ffmpeg=str(ffmpeg),
        dither=args.dither, mono=args.mono)

    print(f"wrote {args.output}: {report.total_bytes} B, "
          f"{report.total_bytes // 512} sectors, {report.frames} frames, "
          f"{report.keyframes} keyframe event(s), "
          f"PSNR mean/worst {report.mean_psnr:.2f}/{report.worst_psnr:.2f} dB, "
          f"{report.seconds_per_mb:.2f} s/MB - OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
