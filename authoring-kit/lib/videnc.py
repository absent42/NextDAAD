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

Retiming (SP17 T0): the Next composites at 50 Hz, so 25 fps is the only
cadence-clean playback rate and --fps 25 is what nearly every title
uses - but almost no source material is 25p. A 30/29.97 source reaching
25 fps by nearest-frame selection drops every 6th frame, and the
measured result is a 73 percent motion spike on every 5th OUTPUT frame
(judder); a 24 fps source instead DUPLICATES one frame per second,
which reads worse still. So whenever the probed source rate differs
from --fps, the frames are now BLENDED to the target rate by default
(retime_plan below has the filter strings and the measurements behind
them). A source already at the target is left completely alone - the
filter chain, and so the encoded bytes, are bit-identical to what they
were before retiming existed. --retime drop restores the old
nearest-frame behaviour; --retime mci opts into motion-compensated
interpolation for slow global motion (pans/zooms).

Quality: NXV v2 is a content-triggered-keyframe, dual-budget (bytes +
modeled decode-T) delta codec - encode time is the main quality lever
(nxv2enc.TMODEL_COEFFS is model-not-silicon; Task 2's bench replaces
it before the format freezes). --report writes the BuildReport
(mean/worst PSNR, keyframe count, bytes, binding-budget histogram) as
JSON next to the output file.

Stream budget (SP17 T1): --stream-budget is a SUPPLY ceiling, not a
quality dial - every metric worsens monotonically as it falls - so no
author should be guessing one. It is DERIVED by default:
nxv2enc.auto_stream_budget searches for the highest budget whose
measured utilization still sits at or under --budget-target (0.90,
margin under the 1.00 refusal line because a whole-clip mean at the
ceiling still bands and judders on hardware), and the encoder prints
what it chose. An explicit --stream-budget skips the search and
applies verbatim.

Tile slack (SP17, owner-approved 2026-07-30): --tile-slack is the ONE
opt-in picture knob, and it is off by default. The budget-bound delta
schedule spends on whole paint-order LINES, walking a ladder of 1/2/4
of them per bound frame and keeping the finest rung that is free in
bytes AND in modelled supply; --tile-slack relaxes the supply half of
that, letting the ladder take the one-row/one-column rung when it costs
a little more supply than the four-line band. What that buys is
content-dependent - measurably better on 320-wide pans and zooms, worth
nothing on quiet material - which is why it is per-title and not a
default. It is quoted in fractions of the utilisation headroom between
--budget-target and the 1.00 refusal line (1.0 = all of it, and the
cap), the cost is printed as a 'tile-slack:' line, and the supply gate
still refuses anything it pushes past the ceiling. The whole-line rung
floor is not reachable from it at any value.

Requires: Python 3, Pillow, numpy. An ffmpeg binary is required at run
time (default: the project's own tools\\ffmpeg\\bin\\ffmpeg.exe,
override with --ffmpeg).
"""

import argparse
import re
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

try:
    from PIL import Image   # noqa: F401 - import-guard only; nxv2enc.py does the real Pillow work
except ImportError:
    print("error: Pillow is required (pip install Pillow)", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FFMPEG = ROOT / "tools" / "ffmpeg" / "bin" / "ffmpeg.exe"

# Source-rate retiming (SP17 T0). See retime_plan for the filter strings
# and the measurements each one comes from.
RETIME_MODES = ("blend", "drop", "mci")
RETIME_MODE_DEFAULT = "blend"
# Source/target rates closer together than this (in fps) count as the
# SAME rate and no retiming filter is inserted at all. It only has to
# absorb ffmpeg's own banner rounding - the banner prints two decimals
# ("29.97 fps" for 30000/1001 = 29.970030), so 0.02 covers that with
# room to spare while still separating every pair of real broadcast
# rates (the closest are 23.976 and 24, 0.024 apart).
RETIME_FPS_TOLERANCE = 0.02
# Blended retiming runs at an INTERMEDIATE resolution, this multiple of
# the target shape on each axis, and the result is then scaled down to
# the target. Free (the retime wave measured 1.4-1.7 s either way) and
# clearly better on Big Buck Bunny - cadence-folded judder 0.024 at 4x
# vs 0.142 blending straight at 320x256 - because blending after the
# downscale averages frames that have already lost the detail whose
# displacement carries the motion.
RETIME_INTERMEDIATE_SCALE = 4


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


def _probe_stderr(ffmpeg, input_path):
    """Runs ffmpeg -i <input_path> with no output and returns its stderr
    banner text (source info: dimensions, stream list) - the single
    shared probe invocation behind probe_dimensions and probe_has_audio,
    so a caller needing both only pays for one ffmpeg process."""
    probe = subprocess.run(
        [str(ffmpeg), "-i", str(input_path)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return probe.stderr.decode("utf-8", "replace")


def probe_dimensions(ffmpeg, input_path, stderr=None):
    """Returns (width, height) of the source's own first video stream,
    read from ffmpeg's own stderr banner (no ffprobe dependency - the
    same probe the center-crop math below and nxv2enc's --shape auto
    picker both need, shared so there is only one implementation). Pass
    stderr= to reuse an already-fetched _probe_stderr() banner."""
    if stderr is None:
        stderr = _probe_stderr(ffmpeg, input_path)
    m = re.search(r",\s*(\d{2,5})x(\d{2,5})[,\s]", stderr)
    if not m:
        raise SystemExit(
            "error: could not detect the source's own dimensions from "
            "ffmpeg's own output")
    return int(m.group(1)), int(m.group(2))


def probe_has_audio(ffmpeg, input_path, stderr=None):
    """True if ffmpeg's own stderr banner for input_path lists an audio
    stream (a "Stream #n:n(...): Audio: ..." line). Used by nxv2enc's
    _extract_source to skip a doomed audio extraction (and the scary raw
    ffmpeg stderr it prints on the way down) when the source is
    video-only, e.g. both SP15 research demo clips. Pass stderr= to
    reuse an already-fetched _probe_stderr() banner."""
    if stderr is None:
        stderr = _probe_stderr(ffmpeg, input_path)
    return re.search(r"Stream #\d+:\d+.*:\s*Audio:", stderr) is not None


def probe_source_fps(ffmpeg, input_path, stderr=None):
    """Returns the source's own nominal frame rate as a float, read from
    the SAME ffmpeg stderr banner probe_dimensions() already parses (the
    "..., 1920x1080 [SAR 1:1 DAR 16:9], 25137 kb/s, 29.97 fps, 29.97
    tbr, ..." video-stream line), or None if the banner carries no fps
    field at all - some containers report only tbr, and an unknown rate
    must not be guessed at. Detection therefore costs no extra probe:
    pass stderr= to reuse an already-fetched _probe_stderr() banner, as
    nxv2enc._extract_source does.

    The banner value is ROUNDED to two decimals by ffmpeg itself, so
    29.97 here is really 30000/1001 - which is exactly why the
    same-rate test below is a tolerance and not an equality."""
    if stderr is None:
        stderr = _probe_stderr(ffmpeg, input_path)
    m = re.search(r",\s*(\d+(?:\.\d+)?)\s+fps[,\s]", stderr)
    if not m:
        return None
    return float(m.group(1))


def retime_plan(src_fps, target_fps, width, height, mode=RETIME_MODE_DEFAULT):
    """Returns (stages, report_line): the ffmpeg -vf stages that carry
    the frames from the (already-applied) crop to the target surface,
    and the one-line report of what was decided.

    The target rate is FIXED by the hardware, not chosen here: the Next
    composites at 50 Hz, so 25 fps is the only cadence-clean rate and
    every source that is not already at it has to be resampled in TIME
    on the way in. How that resampling is done was measured across five
    clips (SP17 T0 wave, 2026-07-28) on a cadence-folded judder metric -
    peak-to-trough of the locally-normalised inter-frame motion, folded
    on the beat cadence; 0 is perfectly even output motion:

      mode   what ffmpeg does                     owner 001  BBB   JF
      drop   nearest source frame (today)           0.458   0.736 0.473
      blend  linear blend of the two neighbours     0.042   0.024 0.027
      mci    motion-compensated interpolation       0.034   0.142 0.023

    blend is the DEFAULT because it is the only one that is uniformly
    good: it cuts the metric by 91-97 percent on every genuinely-30fps
    source and never fails badly. mci is opt-in only - it is the best
    method on slow global motion (the owner's boat pan reaches 0.012 at
    its heaviest preset) but optical flow tears on non-rigid motion, and
    the same heavy preset scores 0.087 on Jellyfish where blend scores
    0.025. Nothing that can be WORSE than the default on ordinary
    content is allowed to be the default.

    Byte cost of blending: NIL on byte-starved content, which is what
    any clip near the streaming supply ceiling is (the wave's clips ran
    92.8-99.2 percent budget-bound, and blend landed within +/-0.6
    percent of drop on bytes at an identical auto-budget and utilization
    - the budget, not the content, is what sets the size). On content
    with headroom the blended frames genuinely carry more detail and it
    costs about 2.3 percent. Quality moves the right way either way:
    +0.12 to +0.6 dB mean PSNR, +0.3 to +1.2 dB on the delta-frame p10.
    Spatial blur is not a real cost at these sizes - 97.7-100.2 percent
    of the source's spatial gradient survives.

    mode "mci" uses the TARGET-resolution preset (minterpolate after the
    downscale, not before it). The wave's three mci presets differ
    mainly in cost: at 4x intermediate resolution obmc/bilat took 38-62 s
    per clip and aobmc/bidir/vsbmc 82-144 s, against 5.5-7.3 s at the
    target resolution - and the cheap one is not the worst one. It is
    the BEST method measured on Jellyfish (0.023) and on Sintel (0.648
    vs 0.734 for blend), and on the owner's own boat pan it scores 0.034
    against 0.012 for the 20x-slower preset. A 20x encode-time
    multiplier for the remaining margin is not a defensible default for
    an opt-in flag, so the target-resolution preset is what --retime mci
    means.

    Passing src_fps=None (rate not detectable from the banner) falls
    back to nearest-frame selection - the pre-SP17 behaviour - rather
    than blending against a guessed rate."""
    if mode is None:
        mode = RETIME_MODE_DEFAULT
    if mode not in RETIME_MODES:
        raise SystemExit(f"error: --retime must be one of "
                          f"{'/'.join(RETIME_MODES)}, got {mode!r}")
    target = float(target_fps)
    plain = [f"scale={width}:{height}"]
    tgt_str = f"{target:g}"
    if src_fps is None:
        return plain, (f"  retime: source rate not detected - target "
                       f"{tgt_str} fps, drop (nearest source frame)")
    src_str = f"{float(src_fps):g}"
    if abs(float(src_fps) - target) <= RETIME_FPS_TOLERANCE:
        return plain, (f"  retime: source {src_str} fps already at "
                       f"{tgt_str} fps target - not retimed")
    if mode == "drop":
        return plain, (f"  retime: source {src_str} fps -> target "
                       f"{tgt_str} fps, drop (nearest source frame)")
    # Exact rational for the filter's own fps option - the same
    # limit_denominator(1000) nxv2enc uses for the encode rate, so
    # e.g. --fps 16.67 becomes 50/3 here too, not a truncated decimal.
    fps_frac = (target_fps if isinstance(target_fps, Fraction)
                else Fraction(target_fps).limit_denominator(1000))
    tgt_arg = fps_arg(fps_frac)
    if mode == "mci":
        stages = [f"scale={width}:{height}",
                  f"minterpolate=fps={tgt_arg}:mi_mode=mci:"
                  f"mc_mode=obmc:me_mode=bilat"]
        return stages, (f"  retime: source {src_str} fps -> target "
                        f"{tgt_str} fps, mci (minterpolate obmc/bilat "
                        f"at {width}x{height})")
    inter_w = width * RETIME_INTERMEDIATE_SCALE
    inter_h = height * RETIME_INTERMEDIATE_SCALE
    stages = [f"scale={inter_w}:{inter_h}",
              f"framerate=fps={tgt_arg}",
              f"scale={width}:{height}"]
    return stages, (f"  retime: source {src_str} fps -> target "
                    f"{tgt_str} fps, blend (framerate filter at "
                    f"{inter_w}x{inter_h})")


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
                   crop=None, stages=None):
    """stages: the -vf stages from the crop to the target surface, as
    built by retime_plan. None means the plain "scale=W:H" that was the
    only thing here before retiming existed - so an unretimed call is
    byte-identical to the pre-SP17 one, output "-r" included (the -r
    stays in every case: with a retiming filter already at the target
    rate it is a no-op, and without one it IS the retiming)."""
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
    vf += list(stages) if stages else [f"scale={width}:{height}"]
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
    ap.add_argument("--retime", choices=list(RETIME_MODES),
                     default=RETIME_MODE_DEFAULT,
                     help="how to resample the source in TIME when its "
                          "own frame rate differs from --fps (default: "
                          "blend). The Next composites at 50 Hz, so 25 "
                          "fps is the only cadence-clean rate and "
                          "23.976/24/29.97/30 material has to be "
                          "retimed to reach it. 'blend' = linear blend "
                          "of the two neighbouring source frames, done "
                          "at 4x the target resolution - cuts the "
                          "measured judder by 91-97 percent, costs "
                          "nothing in bytes on byte-starved content and "
                          "about 2.3 percent on content with headroom. "
                          "'drop' = nearest source frame, the pre-SP17 "
                          "behaviour (drops every 6th frame of a 30 fps "
                          "source, freezes one frame per second of a 24 "
                          "fps one). 'mci' = motion-compensated "
                          "interpolation - OPT-IN, best on slow global "
                          "motion (pans, zooms), but optical flow tears "
                          "on non-rigid motion where it loses to blend. "
                          "A source already at --fps is never retimed "
                          "in any mode")
    ap.add_argument("--mono", action="store_true",
                     help="mono audio (23325 Hz) instead of the "
                          "default stereo (15625 Hz)")
    ap.add_argument("--dither", type=float, default=None, metavar="AMP",
                     help="dither strength, 0.0-1.0 (default: 0.5). In "
                          "the default offset mode it is the blue-noise "
                          "offset depth as a fraction of one lattice "
                          "quantization step (0 = pure nearest-colour "
                          "snap, 1 = a full step). In --dither-mode "
                          "mixture it is the fraction of each pixel's "
                          "quantization error the dither is asked to "
                          "correct (0 = no dither, 1 = the local mean "
                          "reproduces the source)")
    ap.add_argument("--dither-mode", dest="dither_mode",
                     choices=list(nxv2enc.DITHER_MODES),
                     default=nxv2enc.DITHER_MODE_DEFAULT,
                     help="dithering algorithm (default: offset). "
                          "'offset' = one global blue-noise offset per "
                          "pixel, then nearest-colour. 'mixture' = "
                          "Yliluoma positional mixture dithering "
                          "(32-slot luminance-sorted candidate list "
                          "indexed by the same blue-noise tile) - "
                          "OPT-IN: it recovers gradients better on some "
                          "content but loses per-pixel PSNR, carries a "
                          "per-channel mean bias, weakens the drift and "
                          "staleness keyframe triggers and can cost up "
                          "to 26 percent more wire bytes. The default "
                          "encode is byte-identical to what it was "
                          "before this option existed")
    ap.add_argument("--no-merge", dest="no_merge", action="store_true",
                     help="disable the encoder-only gap-merge optimization "
                          "(SP15). Production encodes keep it ON; this is for "
                          "the decode-kernel bench, whose NXB8 real-stream "
                          "fixture must stay dense small ops for the dispatch "
                          "measurement (nxv2enc bench-fixtures merge-bypass "
                          "note)")
    ap.add_argument("--byte-cap", dest="byte_cap", type=float, default=0.65,
                     help="delta per-frame byte cap as a fraction of the "
                          "raw surface (default: 0.65)")
    ap.add_argument("--stream-budget", dest="stream_budget", type=float,
                     default=None,
                     help="scale BOTH delta caps (bytes + decode-T) to fit "
                          "the ring-streaming SD supply. DEFAULT: derived "
                          "automatically - the encoder searches for the "
                          "highest budget whose measured utilization still "
                          "sits at or under --budget-target and reports what "
                          "it chose. Pass a value here to override the "
                          "search outright (it then applies verbatim, gate "
                          "and all)")
    ap.add_argument("--budget-target", dest="budget_target", type=float,
                     default=None, metavar="UTIL",
                     help=f"target mean supply utilization for the automatic "
                          f"--stream-budget search (default: "
                          f"{nxv2enc.AUTO_BUDGET_TARGET_UTIL:.2f}). The "
                          f"margin under 1.00 is deliberate: a whole-clip "
                          f"mean at the ceiling still contains per-frame "
                          f"excursions that band and judder on hardware. "
                          f"Ignored when --stream-budget is given")
    ap.add_argument("--tile-slack", dest="tile_slack", type=float,
                     default=None, metavar="FRAC",
                     help=f"OPT-IN (default: "
                          f"{nxv2enc.TILE_SLACK_DEFAULT:.1f} = off, output "
                          f"unchanged). Lets the adaptive tile ladder take a "
                          f"FINER whole-line rung - one row/column instead of "
                          f"the four-line band - even when that rung costs "
                          f"more modelled supply than the band, in exchange "
                          f"for the picture it buys. Quoted in fractions of "
                          f"the auto-budget utilisation HEADROOM, i.e. of the "
                          f"margin between --budget-target "
                          f"({nxv2enc.AUTO_BUDGET_TARGET_UTIL:.2f}) and the "
                          f"1.00 refusal line: "
                          f"{nxv2enc.TILE_SLACK_MAX:.1f} is the CAP and "
                          f"spends all of that margin. The right value is "
                          f"content-dependent - it helped 320-wide pans and "
                          f"zooms on real hardware and does nothing for quiet "
                          f"material - so try 0.5 first (it SATURATES around "
                          f"there on measured footage) and read the "
                          f"'tile-slack:' report line for what it cost. The "
                          f"whole-line rung floor is NOT reachable from this "
                          f"knob at any value (sub-line rungs tore on "
                          f"silicon), and an encode this pushes past the "
                          f"supply ceiling is REFUSED by the same gate as "
                          f"ever, never quietly shipped")
    ap.add_argument("--direct", action="store_true",
                     help="SP15 3c direct-serve preset: all-literal "
                          "raw-equivalent encode (every frame a full "
                          "keyframe repaint, header direct-serve hint "
                          "set) - the player serves it straight from "
                          "SD to the surface, no ring. Gated by "
                          "worst-frame WIRE feasibility "
                          "(nxv2enc.direct_supply_check); small shapes "
                          "only at 25 fps (raw bytes/frame = WxH). "
                          "TIGHTEN policy (Card #5, 2026-07-26 owner "
                          "ruling): the gate is unconditional - a "
                          "worst-frame utilization above 1.00 refuses "
                          "outright, and prints the at-rate envelope; "
                          "there is no slow-playback override. Use a "
                          "smaller shape, lower --fps, --mono, or drop "
                          "--direct for the delta encoder instead")
    ap.add_argument("--direct-transport-factor", dest="direct_transport_factor",
                     type=float, default=None, metavar="F",
                     help="EXPERT OVERRIDE for the direct-serve gate's "
                          "per-BYTE transport factor - default None uses "
                          "the shipping DIRECT_TRANSPORT_FACTOR (1.00, "
                          "the 2026-08-02 whole-frame silicon re-fit on "
                          "the rebuilt T8 transport; the gate's fixed "
                          "2.2 ms/frame transport overhead is NOT scaled "
                          "by this flag). Probe encodes at a hypothesised "
                          "rate go through this flag instead of editing "
                          "the constant; probe files are diagnostic - a "
                          "slow probe is a measurement, not a defect. "
                          "Only meaningful with --direct")
    ap.add_argument("--prefilter", nargs="?", const="hqdn3d=2:1.5:3:2.25",
                     default=None, metavar="FILTER",
                     help="OPT-IN (W4, default OFF - the extraction "
                          "chain is untouched without it): light "
                          "temporal denoise before scaling, an ffmpeg "
                          "filter string. Bare --prefilter means "
                          "hqdn3d=2:1.5:3:2.25 (half the hqdn3d "
                          "defaults - conservative). Source grain is "
                          "delta demand the wire pays for every frame; "
                          "denoising trades a little texture for "
                          "supply headroom. A MEASURED option for the "
                          "authoring sitting, not a default")
    ap.add_argument("--approx-cuts", dest="approx_cuts", action="store_true",
                     help="EXPERIMENTAL OPT-IN (W4): on budget-bound "
                          "frames, allow the encoder to satisfy the "
                          "byte budget with APPROXIMATE full-coverage "
                          "content (gain-per-byte line triage, cheap "
                          "colour RUNs standing in for unaffordable "
                          "exact repaints) instead of deferring whole "
                          "bands - the C2 corpus experiment's measured "
                          "policy win on cut-heavy starved clips (+4 to "
                          "+9 dB 4x4 there). Wire format unchanged - "
                          "files play on every shipped player. Without "
                          "this flag the encode is byte-identical to "
                          "the default encoder")
    ap.add_argument("--kf-cadence", dest="kf_cadence", type=float,
                     default=None, metavar="SECONDS",
                     help="keyframe cadence window in seconds (default: "
                          "5.0): when no natural keyframe (cut/dissolve/"
                          "staleness/drift) has occurred within the "
                          "window, schedule a ROLLING REFRESH - forced-"
                          "clean coverage of the whole screen spread "
                          "across ordinary delta frames inside the "
                          "normal per-frame budgets (no forced keyframe "
                          "span: its paced repaint held the picture and "
                          "read as a mid-clip pause on hardware). "
                          "Measured FREE in bytes at 5 s as a keyframe "
                          "(-0.1%% for +0.39 dB 4x4 local-mean on a "
                          "slow pan). 0 disables the cadence")
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

    # Both scale the per-frame decode-T/byte caps (nxv2enc.encode_clip's
    # cap_bytes_frac and budget_scale) - 0 or negative produces a
    # zero/negative cap nothing can fit, and above 1.0 scales the usable
    # budget PAST the per-frame decode-T contract usable_budget_t() was
    # derived from (internally, stream_supply_check's own
    # suggested_budget already clamps into this same range; the CLI must
    # match it rather than silently accept an out-of-contract value).
    if not (0 < args.byte_cap <= 1.0):
        raise SystemExit(f"error: --byte-cap must be in (0, 1], got {args.byte_cap}")
    if args.stream_budget is not None and not (0 < args.stream_budget <= 1.0):
        raise SystemExit(f"error: --stream-budget must be in (0, 1], got {args.stream_budget}")
    if args.budget_target is not None and not (0 < args.budget_target <= 1.0):
        raise SystemExit(f"error: --budget-target must be in (0, 1], got {args.budget_target}")
    if args.dither is not None and not (0.0 <= args.dither <= 1.0):
        raise SystemExit(f"error: --dither must be in [0, 1], got {args.dither}")
    if args.kf_cadence is not None and args.kf_cadence < 0:
        raise SystemExit(f"error: --kf-cadence must be >= 0 seconds "
                         f"(0 disables), got {args.kf_cadence}")
    # Expert override, but not an unbounded one: far below the bare-wire
    # byte factor (the 2026-08-02 re-fit measured 0.994 on silicon) or
    # far above the pre-T8 1.20 it is a typo, not a probe.
    if args.direct_transport_factor is not None and not (
            0.5 <= args.direct_transport_factor <= 2.0):
        raise SystemExit(f"error: --direct-transport-factor must be in "
                         f"[0.5, 2.0], got {args.direct_transport_factor}")
    # The knob is capped at exactly the auto-budget margin (see nxv2enc's
    # THE SUPPLY-SLACK KNOB block) - a value past it is not a stronger
    # request, it is a request to spend margin that does not exist.
    if args.tile_slack is not None and not (
            0.0 <= args.tile_slack <= nxv2enc.TILE_SLACK_MAX):
        raise SystemExit(
            f"error: --tile-slack must be in [0.0, "
            f"{nxv2enc.TILE_SLACK_MAX:.1f}], got {args.tile_slack} - it is "
            f"quoted in fractions of the utilisation headroom between the "
            f"budget target and the 1.00 refusal line, so "
            f"{nxv2enc.TILE_SLACK_MAX:.1f} already spends all of it")

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
        dither=args.dither, dither_mode=args.dither_mode,
        mono=args.mono, merge_gaps=not args.no_merge,
        cap_bytes_frac=args.byte_cap, stream_budget=args.stream_budget,
        budget_target=args.budget_target, direct=args.direct,
        retime=args.retime, tile_slack=args.tile_slack,
        direct_transport_factor=args.direct_transport_factor,
        kf_cadence=args.kf_cadence,
        approx_cuts=args.approx_cuts, prefilter=args.prefilter)

    stream_line = ""
    if report.mode == "direct":
        stream_line = (f", DIRECT-SERVE wire util "
                       f"{report.stream_utilization:.2f} "
                       f"(SD {report.stream_sd_ms:.1f} ms/frame, "
                       f"{report.stream_demand_kbs:.0f} KB/s)")
    elif report.stream_checked:
        stream_line = (f", stream util {report.stream_utilization:.2f} "
                       f"(decode {report.stream_busy_ms:.1f} + SD "
                       f"{report.stream_sd_ms:.1f} ms, "
                       f"{report.stream_demand_kbs:.0f} KB/s)")
    print(f"wrote {args.output}: {report.total_bytes} B, "
          f"{report.total_bytes // 512} sectors, {report.frames} frames, "
          f"{report.keyframes} keyframe event(s), "
          f"PSNR mean/worst {report.mean_psnr:.2f}/{report.worst_psnr:.2f} dB, "
          f"{report.seconds_per_mb:.2f} s/MB{stream_line} - OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
