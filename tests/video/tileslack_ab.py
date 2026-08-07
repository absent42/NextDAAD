#!/usr/bin/env python3
"""tile-slack A/B - a repeatable measurement of --tile-slack 0.0 vs 0.5
on THE AUTHORING KIT'S OWN TWO DEMO CLIPS.

WHY THIS EXISTS
---------------
--tile-slack is the encoder's one opt-in picture knob and the manual tells
authors to "try 0.5 first" on a title with sustained motion. The question
this script answers is the one an author actually has: DOES IT HELP ON THE
FOOTAGE THEY GET IN THE BOX - authoring-kit/VIDEO/001.mp4 (the bunny clip)
and 002.mp4 (the jellyfish clip). It is a fresh baseline for those two
clips and nothing else.

IT IS NOT A REPRODUCTION OF THE MANUAL'S BENCHMARK TABLE, AND MUST NOT BE
READ AS ONE. That table (manual/reference/video-format.md, "Tile slack" ->
"What it buys") was measured on two clips called "boat pan" and "church
zoom" which are NOT in this repository - they are silent 2560x1440 and
3840x2160 sources that live outside it. An earlier draft of this script
mapped those names onto VIDEO/001.mp4 and 002.mp4 on the strength of a
stale table in .superpowers/sdd/sp14a-task-4-report.md section 43.2, and
printed a cell-by-cell comparison against the manual. That comparison was
between two different pieces of footage and it is GONE. The manual's table
remains unreproduced, and is recorded there as unconfirmable; nothing here
changes it or compares against it.

THE LESSON, since this project keeps hitting it: a document's file mapping
is a claim, not a fact. Two minutes of ffprobe and one extracted frame
would have caught it. Verify the mapping before you measure through it.

It MEASURES. It does not rule. Nothing here edits the manual, the encoder or
the authoring kit - authoring-kit/lib is imported read-only.

WHAT IT DOES
------------
Four encodes, two per clip:

  ARM A   --tile-slack 0.0   budget DERIVED by the encoder's own search
  ARM B   --tile-slack 0.5   budget PINNED to the value arm A derived

Pinning arm B is the whole point of the design and it is the predecessor
card's method (.superpowers/sdd/sp14a-task-4-report.md section 43.3): a
finer tile rung costs modelled SUPPLY, the auto-budget search pays for
supply with wire bytes, so an unpinned arm B would be free to move its own
supply ceiling and flatter itself. One variable, two settings.

Arm A is not re-encoded at its own pin. auto_stream_budget() returns the
WINNING PASS rather than re-running it (nxv2enc.py, "the accepted budget is
never re-encoded"), so the file arm A writes IS the file a pinned encode at
that budget would write. The predecessor verified that byte-identically.

WHERE THE NUMBERS COME FROM - read this before quoting any of them
------------------------------------------------------------------
The --report BuildReport JSON carries exactly ONE of the four quantities
worth having. The others do not exist in it and are computed here:

  rungs taken       NOT IN THE REPORT. Recovered from encode_clip's own
                    per-frame "mode" strings, which carry an "@<rung>"
                    suffix in PIXELS (nxv2enc.encode_delta). Converted to
                    LINES by dividing by one paint-order line, because the
                    artifact is in display terms. Exact - this is the
                    encoder's own record of what it picked, not an
                    inference.
  stream util       report["stream_utilization"]. Straight from the report,
                    the one column that needs no reconstruction.
  local 4x4 PSNR    NOT IN THE REPORT (report["mean_psnr"] is PER-PIXEL).
                    Computed with nxv2enc.psnr_lm - the encoder's OWN
                    function, on the encoder's OWN source and decoded frame
                    stacks. Exact.
  banding index     NOT IN THE REPORT, and NOT AN ENCODER QUANTITY AT ALL.
                    Reimplemented here from decoded frames, to the
                    definition the predecessor card recorded: the per-line
                    residual coefficient of variation. Spelled out in
                    banding_index() below. IT IS AN ARM-TO-ARM DIRECTION
                    ONLY - the absolute value is on this script's own
                    scale and means nothing on its own. See that docstring.

HOW THE PER-FRAME DATA IS OBTAINED
----------------------------------
nxv2enc.encode() returns a BuildReport and throws the per-frame record away.
This script therefore runs the encode IN-PROCESS through videnc.main() -
the real CLI, so every default is the shipped one - with a read-only spy
wrapped around nxv2enc.encode_clip that keeps each pass's return value.
The spy calls the real function and returns its real result unchanged; it
cannot alter a single output byte.

The auto-budget search runs several passes, so the spy keys them by the
budget_scale each was called with and the winning pass is selected by the
budget the report says was accepted. With an explicit --stream-budget (arm
B) there is only ever one pass.

DETERMINISM
-----------
Each encode runs in a FRESH subprocess (this file re-invoked with --worker),
so no memo or LRU carries between them. Same inputs, same numbers. The
encoder and source identities are hashed into every result file and printed
with the table.

USAGE
-----
    python tests/video/tileslack_ab.py              # measure and print
    python tests/video/tileslack_ab.py --force      # ignore cached results
    python tests/video/tileslack_ab.py --clip bunny # one clip only

Work directory: tests/out/tileslack/ (gitignored). Results are cached on a
key made of the encoder hashes, the source hash and the encode arguments, so
a re-run after nothing changed costs nothing and prints the same table.

The picture is judged separately, on hardware:
    .\\tests\\build-tests.ps1 -TileSlack
    docs/superpowers/tileslack-ab-run-sheet.md
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KIT_LIB = ROOT / "authoring-kit" / "lib"
FFMPEG = ROOT / "tools" / "ffmpeg" / "bin" / "ffmpeg.exe"
WORK = ROOT / "tests" / "out" / "tileslack"

# THE TWO CLIPS THE AUTHORING KIT SHIPS. Identities verified directly -
# ffprobe for the shape, an extracted frame looked at for the content - not
# taken from any document:
#
#   VIDEO/001.mp4  Big Buck Bunny, 320x256 @25, 10.000 s, already at the
#                  full shape (no crop, straight scale)
#   VIDEO/002.mp4  jellyfish, 256x192 @25, 10.000 s (upscaled to 320x256
#                  by the encode, which is why its absolute PSNR is lower
#                  than the bunny's - that is the source, not the knob)
#
# Both encoded `full` 320x256 at 25 fps, the kit's own default shape, so
# the two arms of each pair differ in exactly one thing. NOTE that the
# kit's CONFIG.BAT sets VIDOPTS_002=--shape 16:9, so a kit BUILD encodes
# 002 at 320x192; this test uses `full` for both because the tile ladder's
# behaviour is shape-dependent and holding the shape fixed across the two
# pairs is what makes them comparable to each other.
#
# NO --start / --duration: the whole 10.000 s of each, 250 frames.
CLIPS = {
    "bunny": {
        "label": "bunny",
        "src": ROOT / "authoring-kit" / "VIDEO" / "001.mp4",
    },
    "jellyfish": {
        "label": "jellyfish",
        "src": ROOT / "authoring-kit" / "VIDEO" / "002.mp4",
    },
}

SHAPE = "full"
FPS = "25"
ARMS = (0.0, 0.5)

# BUMP THIS whenever anything that could MOVE A NUMBER changes in this
# file: how an encode is invoked, which pass is selected, or how any of the
# four columns is computed. It is part of the result cache key, so bumping
# it re-encodes; not bumping it after a real change would print stale
# numbers under a corrected method, which is the one failure this script
# must not have. Cosmetic and print-only edits do NOT bump it - a full run
# is minutes of encoding and forcing one for a wording fix would just
# discourage running it.
#   1  first cut
#   2  rung reader fixed - the ":roll" suffix encode_clip appends AFTER
#      the "@<rung>" made an end-anchored match miss half the bunny
#      clip's bound frames; raw mode strings are now stored with the result
MEASURE_VERSION = 2

# NO TABLE OF PUBLISHED FIGURES IS QUOTED HERE, DELIBERATELY. The manual's
# --tile-slack benchmark table was measured on two clips that are not in
# this repository, so printing it beside these numbers would invite a
# comparison between different footage. This script's output stands on its
# own as a baseline for the kit's own clips. Do not add one back.

# The encoder's at-capacity line - nxv2enc.STREAM_WARN_UTIL. Read from the
# encoder at run time rather than copied, so it cannot drift.
def warn_util():
    try:
        sys.path.insert(0, str(KIT_LIB))
        import nxv2enc
        return float(nxv2enc.STREAM_WARN_UTIL)
    except Exception:                                # noqa: BLE001
        return None


# ---------------------------------------------------------------------
# identity - everything that could move a number, hashed
# ---------------------------------------------------------------------

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git(*args):
    try:
        out = subprocess.run(["git", "-C", str(ROOT), *args],
                             capture_output=True, text=True, timeout=30)
        return out.stdout.strip() if out.returncode == 0 else "?"
    except Exception:
        return "?"


def identity():
    """Everything that decides the numbers, in one dict. Printed with the
    table and hashed into every cached result."""
    enc = KIT_LIB / "nxv2enc.py"
    cli = KIT_LIB / "videnc.py"
    dirty = git("status", "--porcelain", "--", "authoring-kit/lib")
    return {
        "commit": git("rev-parse", "HEAD"),
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "nxv2enc_sha256": sha256(enc),
        "videnc_sha256": sha256(cli),
        "kit_lib_dirty": bool(dirty),
        "shape": SHAPE,
        "fps": FPS,
    }


# ---------------------------------------------------------------------
# THE BANDING INDEX - read this before comparing it with the document
# ---------------------------------------------------------------------

def banding_index(orig, dec, modes, column_major):
    """The per-line residual coefficient of variation, and the line peak.

    DEFINITION IMPLEMENTED, in full, so it can be checked:

      RESIDUAL is the error left on the displayed surface: for frame i,
      the per-pixel squared difference between the SOURCE frame and the
      DECODED frame, summed over the three channels. That is the "un-updated
      error" the definition names - what the schedule did not get to.

      A LINE is one paint-order line: a ROW at 256 wide (mode 0) and a
      COLUMN at 320 wide (mode 1, column-major addressing). The per-line
      residual is the mean of the frame's residual over that line's pixels.

      Per frame, CV = stdev(line residuals) / mean(line residuals) and
      PEAK = max(line residual) / mean(line residual). The index is the
      MEAN of the per-frame CVs over DELTA frames only; keyframe frames
      repaint everything and have no deferred error to pile up, so
      including them would dilute exactly what is being measured.

      Lower is better: the un-updated error is spread evenly rather than
      piling into whole lines.

    WHAT THIS IS NOT. It is not an encoder quantity and it is not
    comparable with any published figure. It follows the definition the
    predecessor card recorded (sp14a-task-4-report.md section 43.5) and
    computes it post-hoc from decoded frames, which is the only route open
    to a script that may not modify the encoder. The encoder's own internal
    residual is an err2 quantity in palette space, and it does NOT include
    the quantization/dither floor that a source-vs-decoded difference does.
    A uniform floor damps a coefficient of variation, so this number sits
    LOWER than an encoder-internal one would on the same clip. READ THE
    ARM-TO-ARM DIRECTION AND SIZE, NOTHING ELSE - the absolute value is on
    this script's own scale and carries no meaning outside this comparison.
    """
    import numpy as np
    cvs, peaks = [], []
    for i, mode in enumerate(modes):
        if mode.startswith("kf"):
            continue
        a = np.asarray(orig[i], dtype=np.float32)
        b = np.asarray(dec[i], dtype=np.float32)
        err = ((a - b) ** 2).sum(axis=2)          # (H, W) residual
        line = err.mean(axis=0) if column_major else err.mean(axis=1)
        m = float(line.mean())
        if m <= 0.0:
            continue
        cvs.append(float(line.std()) / m)
        peaks.append(float(line.max()) / m)
    if not cvs:
        return None, None, 0
    return sum(cvs) / len(cvs), sum(peaks) / len(peaks), len(cvs)


def rungs_from_modes(modes, line_px):
    """The "rungs taken" column, from encode_clip's own per-frame mode
    strings.

    A bound frame's mode carries "@<rung>" with the rung in PIXELS, and may
    carry a further ":roll" suffix after it (rolling-refresh frames), so the
    rung is read up to the next colon rather than to the end of the string.
    Frames the ladder never ran on - the ones that were not budget-bound -
    carry no "@" at all and are not counted, which is what "taken" means.

    line_px is one paint-order line: the frame HEIGHT in column-major
    mode-1 (320 wide) and the WIDTH in row-major mode-0.

    Returns (text, {lines: count}, frames-with-a-rung).
    """
    counts = Counter()
    total = 0
    for s in modes:
        m = re.search(r"@(\d+)(?::|$)", s)
        if not m:
            continue
        px = int(m.group(1))
        counts[px // line_px if px % line_px == 0 else px] += 1
        total += 1
    text = ", ".join(f"{k}-line x{v}" for k, v in
                     sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))
    return text, {str(k): v for k, v in sorted(counts.items())}, total


# ---------------------------------------------------------------------
# worker - one encode, in-process, with the read-only spy
# ---------------------------------------------------------------------

class _Tee:
    """Keep the encoder's console output AND record it."""

    def __init__(self, stream, sink):
        self._s = stream
        self._sink = sink

    def write(self, text):
        self._sink.append(text)
        return self._s.write(text)

    def flush(self):
        self._s.flush()

    def isatty(self):
        return False


def run_worker(clip, slack, pin, out_dir):
    """Encode one arm and write its metrics JSON. Runs in its own process."""
    sys.path.insert(0, str(KIT_LIB))
    import numpy as np
    import nxv2enc
    import videnc

    spec = CLIPS[clip]
    tag = f"{clip}_s{slack:.2f}".replace(".", "")
    vid = out_dir / f"{tag}.vid"
    rep = out_dir / f"{tag}.report.json"
    met = out_dir / f"{tag}.metrics.json"

    argv = ["videnc.py", str(spec["src"]), str(vid),
            "--shape", SHAPE, "--fps", FPS,
            "--tile-slack", f"{slack}",
            "--report", str(rep),
            "--ffmpeg", str(FFMPEG)]
    if pin is not None:
        argv += ["--stream-budget", f"{pin:.2f}"]

    # ---- the spy. Calls the real encode_clip, returns its real result,
    # keeps a reference keyed by the budget that pass was run at. Read-only
    # by construction: it neither inspects nor rewrites any argument.
    real_encode_clip = nxv2enc.encode_clip
    passes = {}
    sources = {}

    def spy(*a, **kw):
        result = real_encode_clip(*a, **kw)
        key = round(float(kw.get("budget_scale", 1.0)), 4)
        passes[key] = result
        sources[key] = a[0]          # ex["orig"], the extracted source stack
        return result

    nxv2enc.encode_clip = spy
    console = []
    t0 = time.time()
    status, err = "ok", None
    try:
        sys.stdout = _Tee(sys.__stdout__, console)
        try:
            videnc.main(argv)
        finally:
            sys.stdout = sys.__stdout__
    except SystemExit as e:
        # The supply gate refuses rather than shipping an unstreamable
        # file. That is a RESULT, not a crash - record it and leave the
        # cells blank rather than inventing them.
        status, err = "refused", str(e)
    except Exception as e:                          # noqa: BLE001
        status, err = "error", f"{type(e).__name__}: {e}"
    finally:
        nxv2enc.encode_clip = real_encode_clip
    elapsed = time.time() - t0

    out = {
        "clip": clip, "label": spec["label"], "slack": slack,
        "pin": pin, "argv": argv[1:], "status": status, "error": err,
        "elapsed_s": round(elapsed, 1),
        "identity": identity(),
        "source_sha256": sha256(spec["src"]),
        "console": "".join(console).splitlines(),
    }

    if status == "ok":
        report = json.loads(rep.read_text())
        out["report"] = report
        out["vid_sha256"] = sha256(vid)
        out["vid_bytes"] = vid.stat().st_size

        # Which pass wrote the file: the one run at the budget the report
        # says was accepted. Unique by construction - auto_stream_budget
        # never probes the same budget twice, and a pinned encode runs one
        # pass.
        want = round(float(report["stream_budget"]), 4)
        result = passes.get(want)
        if result is None and len(passes) == 1:
            result = next(iter(passes.values()))
            want = next(iter(passes))
        if result is None:
            out["status"] = "no-pass"
            out["error"] = (f"no encode_clip pass at budget {want} "
                            f"(saw {sorted(passes)})")
            met.write_text(json.dumps(out, indent=1))
            return 1

        orig = sources[want]
        dec = result["decoded"]
        modes = result["per_frame"]["mode"]
        width, height = report["shape"]
        column_major = (width == 320)
        n = min(len(orig), len(dec), len(modes))

        # ---- rungs taken. The mode string carries "@<rung-in-pixels>",
        # and it may carry a further ":roll" suffix on rolling-refresh
        # frames (encode_clip appends it AFTER the rung) - so the rung is
        # matched up to the next colon or the end of the string, never
        # anchored at the end. Anchoring it undercounted the bunny clip
        # by half on the first run of this script.
        # One paint-order line is `height` px in column-major mode-1 and
        # `width` px in row-major mode-0 (nxv2enc.default_tile_px), so the
        # rung in LINES - the unit the artifact is in - is the ratio.
        out["modes"] = list(modes[:n])       # kept raw: the rung column is
                                             # then recomputable from a
                                             # cached result, with no
                                             # re-encode
        out["rungs_taken"], out["rungs_by_lines"], out["ladder_frames"] = \
            rungs_from_modes(modes[:n], height if column_major else width)

        # ---- local 4x4 PSNR, with the encoder's own function on the
        # encoder's own arrays.
        lm = [float(nxv2enc.psnr_lm(np.asarray(orig[i]), np.asarray(dec[i])))
              for i in range(n)]
        lm_delta = [v for v, m in zip(lm, modes[:n]) if not m.startswith("kf")]
        out["psnr_4x4"] = sum(lm) / len(lm) if lm else None
        out["psnr_4x4_delta_only"] = (sum(lm_delta) / len(lm_delta)
                                      if lm_delta else None)

        # ---- banding index (see banding_index's docstring)
        band, peak, nband = banding_index(orig[:n], dec[:n], modes[:n],
                                          column_major)
        out["banding_index"] = band
        out["line_peak"] = peak
        out["banding_frames"] = nband

        out["frames"] = n
        out["delta_frames"] = sum(1 for m in modes[:n] if not m.startswith("kf"))
        out["column_major"] = column_major

    met.write_text(json.dumps(out, indent=1))
    return 0 if out["status"] == "ok" else 1


# ---------------------------------------------------------------------
# parent - drive the four encodes, then print the table
# ---------------------------------------------------------------------

def cache_key(clip, slack, pin, ident):
    """What a cached result is keyed on: everything that decides the
    NUMBERS, and nothing that decides what they are CALLED.

    The clip's NAME is deliberately not in here - the source file's hash
    already identifies the clip, exactly and without depending on anyone's
    label being right. This fixture was relabelled once already (it shipped
    naming two clips it does not contain), and a rename is not a reason to
    spend twenty minutes re-encoding footage that has not changed."""
    spec = CLIPS[clip]
    return hashlib.sha256(json.dumps({
        "slack": slack, "pin": pin,
        "src": sha256(spec["src"]),
        "enc": ident["nxv2enc_sha256"], "cli": ident["videnc_sha256"],
        # This script too: it computes three of the four columns, so a
        # change to how it MEASURES must invalidate a cached measurement
        # exactly as a change to the encoder does. Declared, not hashed -
        # see MEASURE_VERSION.
        "measure": MEASURE_VERSION,
        "shape": SHAPE, "fps": FPS,
    }, sort_keys=True).encode()).hexdigest()[:16]


def refresh_derived(got, clip=None):
    """Recompute the columns that are pure functions of the stored raw
    data, and re-stamp the clip's NAME.

    The worker stores encode_clip's per-frame mode strings verbatim, so a
    correction to the rung reader applies to CACHED results without
    re-encoding anything - which matters, because a full arm-A pass is
    minutes and a miscounted rung column looks exactly like a real result.
    The name is re-stamped for the same reason: a cached result carries
    whatever the clip was called when it was encoded, and the numbers do
    not change when that turns out to have been wrong."""
    if clip:
        got["clip"] = clip
        got["label"] = CLIPS[clip]["label"]
    if got.get("status") == "ok" and got.get("modes"):
        w, h = got["report"]["shape"]
        (got["rungs_taken"], got["rungs_by_lines"],
         got["ladder_frames"]) = rungs_from_modes(got["modes"],
                                                  h if w == 320 else w)
    return got


def encode_arm(clip, slack, pin, ident, force):
    tag = f"{clip}_s{slack:.2f}".replace(".", "")
    met = WORK / f"{tag}.metrics.json"
    key = cache_key(clip, slack, pin, ident)
    if met.exists() and not force:
        try:
            got = json.loads(met.read_text())
            if got.get("cache_key") == key:
                print(f"  {tag}: cached ({got['status']})")
                return refresh_derived(got, clip)
        except Exception:                            # noqa: BLE001
            pass
    argv = [sys.executable, str(Path(__file__).resolve()),
            "--worker", "--clip", clip, "--slack", str(slack)]
    if pin is not None:
        argv += ["--pin", f"{pin:.2f}"]
    print(f"  {tag}: encoding"
          + (f" (budget pinned {pin:.2f})" if pin is not None
             else " (budget derived)") + " ...")
    subprocess.run(argv, cwd=str(ROOT))
    if not met.exists():
        return {"clip": clip, "slack": slack, "status": "missing",
                "error": "worker produced no metrics file"}
    got = json.loads(met.read_text())
    got["cache_key"] = key
    met.write_text(json.dumps(got, indent=1))
    return refresh_derived(got, clip)


def fmt(v, spec="{:.3f}"):
    return "-" if v is None else spec.format(v)


def arm_delta(b, a, spec="{:+.3f}"):
    """Arm B minus arm A - the only comparison this script makes."""
    if a is None or b is None:
        return "-"
    return spec.format(b - a)


def print_tables(results):
    ident = identity()
    print()
    print("=" * 78)
    print("TILE-SLACK A/B ON THE AUTHORING KIT'S OWN DEMO CLIPS - MEASURED")
    print("=" * 78)
    print(f"repo commit        {ident['commit']} ({ident['branch']})")
    print(f"nxv2enc.py sha256  {ident['nxv2enc_sha256']}")
    print(f"videnc.py  sha256  {ident['videnc_sha256']}")
    if ident["kit_lib_dirty"]:
        print("WARNING: authoring-kit/lib has uncommitted changes - these "
              "numbers are not from a committed encoder")
    print(f"shape              {SHAPE} 320x256, {FPS} fps, whole clip, "
          f"all other options at their shipped defaults")
    print("budget             derived by the encoder on ARM A (slack 0.0), "
          "then PINNED on ARM B")
    print("NOT a reproduction of the manual's --tile-slack benchmark table.")
    print("That table was measured on two clips (\"boat pan\", \"church "
          "zoom\") that are")
    print("NOT in this repository. Nothing here is compared against it and "
          "nothing here")
    print("confirms or refutes it - it stays recorded in the manual as "
          "unconfirmable.")
    print()
    for clip in CLIPS:
        r = results.get((clip, 0.0))
        if r and r.get("status") == "ok":
            print(f"{CLIPS[clip]['label']:<10} authoring-kit/VIDEO/"
                  f"{CLIPS[clip]['src'].name}  "
                  f"sha256 {r['source_sha256'][:16]}  "
                  f"pin {r['report']['stream_budget']:.2f} "
                  f"({r['report']['auto_budget_probes']} probes)  "
                  f"{r['frames']} frames ({r['delta_frames']} delta)")
    print()

    head = ("| clip | slack | rungs taken | stream util | "
            "local (4x4) PSNR | banding index |")
    print(head)
    print("|:--|--:|:--|--:|--:|--:|")
    for clip in CLIPS:
        for slack in ARMS:
            r = results.get((clip, slack))
            lab = CLIPS[clip]["label"]
            if not r or r.get("status") != "ok":
                why = (r or {}).get("status", "not run")
                print(f"| {lab} | {slack:.1f} | NOT MEASURED ({why}) "
                      f"| - | - | - |")
                continue
            print(f"| {lab} | {slack:.1f} | {r['rungs_taken'] or '(none)'} "
                  f"| {r['report']['stream_utilization']:.3f} "
                  f"| {fmt(r['psnr_4x4'], '{:.2f}')} "
                  f"| {fmt(r['banding_index'])} |")

    # ---- THE ONLY COMPARISON THIS SCRIPT MAKES: arm B minus arm A, within
    # a clip, at the same pinned budget. One variable, two settings.
    print()
    print("=" * 78)
    print("WHAT THE KNOB DID - ARM B (0.5) MINUS ARM A (0.0), PER CLIP")
    print("=" * 78)
    print("| clip | stream util | local (4x4) PSNR | banding index "
          "| bytes | 1-line rung |")
    print("|:--|--:|--:|--:|--:|--:|")
    for clip in CLIPS:
        a, b = results.get((clip, 0.0)), results.get((clip, 0.5))
        lab = CLIPS[clip]["label"]
        if not a or not b or a.get("status") != "ok" or b.get("status") != "ok":
            print(f"| {lab} | NOT MEASURED | - | - | - | - |")
            continue
        a1 = a["rungs_by_lines"].get("1", 0)
        b1 = b["rungs_by_lines"].get("1", 0)
        print(f"| {lab} "
              f"| {arm_delta(b['report']['stream_utilization'], a['report']['stream_utilization'])} "
              f"| {arm_delta(b['psnr_4x4'], a['psnr_4x4'], '{:+.2f}')} dB "
              f"| {arm_delta(b['banding_index'], a['banding_index'])} "
              f"| {b['vid_bytes'] - a['vid_bytes']:+,} "
              f"| {a1} -> {b1} frames |")
    print()
    print("Lower banding index is better (the un-updated error is spread "
          "evenly rather")
    print("than piling into whole lines). Higher PSNR is better. Higher "
          "utilisation is")
    print("the COST - see the at-capacity section below.")

    print()
    print("=" * 78)
    print("WHAT EACH COLUMN IS, AND HOW FAR TO TRUST IT")
    print("=" * 78)
    print(
        "rungs taken       EXACT. encode_clip's own per-frame mode strings,\n"
        "                  converted from pixels to paint-order lines. Not in\n"
        "                  the --report JSON; recovered in-process.\n"
        "stream util       EXACT. report['stream_utilization'], the only one\n"
        "                  of the four the BuildReport actually carries.\n"
        "local (4x4) PSNR  EXACT. nxv2enc.psnr_lm over the encoder's own\n"
        "                  source and decoded stacks. Not in the report -\n"
        "                  report['mean_psnr'] is PER-PIXEL, a different\n"
        "                  number, and must not be read into this column.\n"
        "banding index     RECOMPUTED, AND AN ARM-TO-ARM DIRECTION ONLY. No\n"
        "                  encoder or report field holds this quantity; it is\n"
        "                  the recorded DEFINITION (per-line residual\n"
        "                  coefficient of variation) implemented post-hoc from\n"
        "                  decoded frames - see banding_index() in this file\n"
        "                  for the exact arithmetic. Its ABSOLUTE value is on\n"
        "                  this script's own scale and is not comparable with\n"
        "                  any published figure. Read the sign and the size of\n"
        "                  the arm-to-arm move, nothing else.")
    print()
    print("Supporting figures:")
    print("| clip | slack | budget | bytes | per-pixel PSNR | bound% "
          "| ladder frames | line peak | probes |")
    print("|:--|--:|--:|--:|--:|--:|--:|--:|--:|")
    for clip in CLIPS:
        for slack in ARMS:
            r = results.get((clip, slack))
            if not r or r.get("status") != "ok":
                continue
            rep = r["report"]
            print(f"| {CLIPS[clip]['label']} | {slack:.1f} "
                  f"| {rep['stream_budget']:.2f} | {r['vid_bytes']:,} "
                  f"| {rep['mean_psnr']:.2f} | {rep['bound_fraction']:.1%} "
                  f"| {r['ladder_frames']}/{r['delta_frames']} "
                  f"| {fmt(r['line_peak'], '{:.2f}')} "
                  f"| {rep['auto_budget_probes']} |")
    # ---- what the encoder itself said. The budget line, the tile-slack
    # cost line and any gate WARNING are operational facts no column above
    # carries, and the at-capacity warning is the most important thing this
    # measurement found.
    print()
    print("=" * 78)
    print("WHAT THE ENCODER SAID (its own lines, verbatim)")
    print("=" * 78)
    warned = []
    for clip in CLIPS:
        for slack in ARMS:
            r = results.get((clip, slack))
            if not r:
                continue
            keep = [ln.strip() for ln in r.get("console", [])
                    if ("auto-budget:" in ln or "tile-slack:" in ln
                        or "warning:" in ln or "error:" in ln)]
            if not keep:
                continue
            print(f"{CLIPS[clip]['label']} slack {slack:.1f}:")
            for ln in keep:
                print(f"  {ln}")
                if "warning:" in ln or "error:" in ln:
                    warned.append((CLIPS[clip]["label"], slack,
                                   r["report"]["stream_utilization"]))
    if warned:
        wu = warn_util()
        print()
        print("#" * 78)
        print("## AT-CAPACITY FINDING - THE HEADLINE OF THIS RUN")
        print("#" * 78)
        for lab, slack, util in warned:
            print(f"  {lab} at --tile-slack {slack:.1f}: utilisation "
                  f"{util:.3f}"
                  + (f" against STREAM_WARN_UTIL {wu:.2f}" if wu else "")
                  + " - OVER THE LINE")
        print()
        print("Applying the manual's own '--tile-slack 0.5' suggestion to "
              "THE KIT'S OWN")
        print("DEMO CLIPS trips the encoder's at-capacity warning. That is "
              "the footage")
        print("every new author starts from, so this is a live authoring "
              "trap, not a")
        print("laboratory curiosity. The gate's own words: the whole-clip "
              "mean hides")
        print("per-frame excursions well over 1.00, which read as banding "
              "and judder on")
        print("hardware.")
        print()
        print("It is REPORTED, not fixed. Nothing here changes the encoder, "
              "the default")
        print("(still 0.0, off) or the manual. Two things follow for whoever "
              "acts on it:")
        print("  - watch those arms for JUDDER and audio breakup "
              "specifically (run sheet,")
        print("    leg 3) - a picture verdict and a supply verdict are "
              "different findings;")
        print("  - the predecessor card DISCARDED a pair in this state and "
              "re-encoded both")
        print("    arms at a lower pinned budget rather than compare across "
              "it")
        print("    (sp14a-task-4-report.md section 43.6). Whether to do that "
              "here is a")
        print("    ruling, not a measurement.")

    print()
    print("THE NUMBERS AND THE PICTURE CAN DISAGREE. Nothing above judges "
          "what the")
    print("clip LOOKS like on a Next. Stage the fixture and watch it:")
    print("    .\\tests\\build-tests.ps1 -TileSlack")
    print("    docs\\superpowers\\tileslack-ab-run-sheet.md")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--clip", choices=sorted(CLIPS), default=None,
                    help="measure one clip only (default: both)")
    ap.add_argument("--force", action="store_true",
                    help="re-encode even when a cached result matches")
    ap.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--slack", type=float, default=None,
                    help=argparse.SUPPRESS)
    ap.add_argument("--pin", type=float, default=None, help=argparse.SUPPRESS)
    args = ap.parse_args()

    WORK.mkdir(parents=True, exist_ok=True)

    if args.worker:
        return run_worker(args.clip, args.slack, args.pin, WORK)

    if not FFMPEG.exists():
        print(f"ERROR: no ffmpeg at {FFMPEG}")
        return 2
    ident = identity()
    clips = [args.clip] if args.clip else list(CLIPS)
    missing = [c for c in clips if not CLIPS[c]["src"].exists()]
    if missing:
        for c in missing:
            print(f"ERROR: {CLIPS[c]['src']} is missing - cannot measure "
                  f"{CLIPS[c]['label']}")
        return 2

    results = {}
    for clip in clips:
        print(f"{CLIPS[clip]['label']} ({CLIPS[clip]['src'].name}):")
        # ARM A first: it derives the budget both arms then run at.
        a = encode_arm(clip, 0.0, None, ident, args.force)
        results[(clip, 0.0)] = a
        if a.get("status") != "ok":
            print(f"  arm A failed ({a.get('status')}: {a.get('error')}) - "
                  f"arm B has no budget to pin and is skipped")
            results[(clip, 0.5)] = {"status": "skipped",
                                    "error": "arm A produced no budget"}
            continue
        pin = round(float(a["report"]["stream_budget"]), 2)
        b = encode_arm(clip, 0.5, pin, ident, args.force)
        results[(clip, 0.5)] = b
        if b.get("status") == "refused":
            print(f"  arm B REFUSED by the supply gate at the pinned budget "
                  f"{pin:.2f} - that is a result, see the run sheet")

    print_tables(results)
    (WORK / "summary.json").write_text(json.dumps(
        {f"{c}_{s}": v for (c, s), v in results.items()}, indent=1))
    print(f"\nresults: {WORK}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
