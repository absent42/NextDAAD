#!/usr/bin/env python3
"""tile-slack A/B - a repeatable measurement of --tile-slack 0.0 vs 0.5.

WHY THIS EXISTS
---------------
manual/reference/video-format.md carries a four-row benchmark table for
--tile-slack (two clips, two slack values, four columns). No row of it is
reproducible from anything in this repository, and the nearest live source
- the SUPPLY-SLACK KNOB block in authoring-kit/lib/nxv2enc.py - records the
same experiment on the same clip with DIFFERENT numbers. This script
re-measures the experiment from scratch so the owner can see, cell by cell,
which of the document's figures the current encoder reproduces.

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
The --report BuildReport JSON carries exactly ONE of the document's four
columns. The others do not exist in it and are computed here:

  rungs taken       NOT IN THE REPORT. Recovered from encode_clip's own
                    per-frame "mode" strings, which carry an "@<rung>"
                    suffix in PIXELS (nxv2enc.encode_delta). Converted to
                    LINES by dividing by one paint-order line, so the units
                    match the document's "4-line x237" form. Exact - this is
                    the encoder's own record of what it picked, not an
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
                    banding_index() below. READ THAT DOCSTRING BEFORE
                    COMPARING IT WITH THE DOCUMENT'S COLUMN - it is a
                    faithful implementation of the stated definition, but
                    the estimator that produced the document's figure was
                    never published, so the two are not known to be on the
                    same scale.

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
    python tests/video/tileslack_ab.py             # measure and print
    python tests/video/tileslack_ab.py --force     # ignore cached results
    python tests/video/tileslack_ab.py --clip boat # one clip only

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

# The two clips the document's table names. Both are encoded at the SHAPE
# the document measured ("real 320x256 footage") and the predecessor card
# staged (full, mode-1, 25 fps), which is NOT what authoring-kit/CONFIG.BAT
# would use for 002 (VIDOPTS_002=--shape 16:9) - see the report.
#
# NO --start / --duration. The predecessor card cut boat pan at
# --start 00:00:02 for 10.0 s and church zoom to 9.5 s; neither cut is
# reproducible against the source files now in authoring-kit/VIDEO (both are
# exactly 10.000 s, so a 2 s start cannot yield a 10 s clip). The whole clip
# is the one cut that is unambiguous today.
CLIPS = {
    "boat": {
        "label": "boat pan",
        "src": ROOT / "authoring-kit" / "VIDEO" / "001.mp4",
    },
    "church": {
        "label": "church zoom",
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
#      the "@<rung>" made an end-anchored match miss half the boat pan's
#      bound frames; raw mode strings are now stored with the result
MEASURE_VERSION = 2

# manual/reference/video-format.md, the "What it buys" table under
# "Tile slack". Quoted here ONLY to be printed beside the measurement.
# NOT a target, NOT an assertion - nothing in this script fails because a
# measured cell disagrees with one of these.
DOC = {
    ("boat", 0.0): {
        "rungs": "4-line x237, 2-line x10",
        "util": 0.882, "psnr4": 32.02, "band": 0.912,
    },
    ("boat", 0.5): {
        "rungs": "1-line x195, 2-line x30, 4-line x22",
        "util": 0.890, "psnr4": 32.33, "band": 0.910,
    },
    ("church", 0.0): {
        "rungs": "4-line x205, 1-line x18",
        "util": 0.874, "psnr4": 34.90, "band": 1.243,
    },
    ("church", 0.5): {
        "rungs": "1-line x185, 2-line x26, 4-line x24",
        "util": 0.879, "psnr4": 34.91, "band": 1.166,
    },
}
DOC_SOURCE = "manual/reference/video-format.md, 'Tile slack' -> 'What it buys'"


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

    WHAT THIS IS NOT. The estimator that produced the document's banding
    index column was never published. This one follows the definition the
    predecessor card recorded (sp14a-task-4-report.md section 43.5) and
    computes it post-hoc from decoded frames, which is the only route open
    to a script that may not modify the encoder. The encoder's own internal
    residual is an err2 quantity in palette space, and it does NOT include
    the quantization/dither floor that a source-vs-decoded difference does.
    A uniform floor damps a coefficient of variation, so this number can sit
    LOWER than an encoder-internal one on the same clip. The arm-to-arm
    DIRECTION and RATIO are the parts to read; treat the absolute value as
    this script's own scale, not as the document's.
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
    """The document's "rungs taken" column, from encode_clip's own
    per-frame mode strings.

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
        # anchored at the end. Anchoring it undercounted the boat pan by
        # half on the first run of this script.
        # One paint-order line is `height` px in column-major mode-1 and
        # `width` px in row-major mode-0 (nxv2enc.default_tile_px), so the
        # rung in LINES - the document's unit - is the ratio.
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
    spec = CLIPS[clip]
    return hashlib.sha256(json.dumps({
        "clip": clip, "slack": slack, "pin": pin,
        "src": sha256(spec["src"]),
        "enc": ident["nxv2enc_sha256"], "cli": ident["videnc_sha256"],
        # This script too: it computes three of the four columns, so a
        # change to how it MEASURES must invalidate a cached measurement
        # exactly as a change to the encoder does. Declared, not hashed -
        # see MEASURE_VERSION.
        "measure": MEASURE_VERSION,
        "shape": SHAPE, "fps": FPS,
    }, sort_keys=True).encode()).hexdigest()[:16]


def refresh_derived(got):
    """Recompute the columns that are pure functions of the stored raw
    data. The worker stores encode_clip's per-frame mode strings verbatim,
    so a correction to the rung reader applies to CACHED results without
    re-encoding anything - which matters, because a full arm-A pass is
    minutes and a miscounted rung column looks exactly like a real
    disagreement with the document."""
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
                return refresh_derived(got)
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
    return refresh_derived(got)


def fmt(v, spec="{:.3f}"):
    return "-" if v is None else spec.format(v)


def delta(measured, doc, spec="{:+.3f}"):
    if measured is None or doc is None:
        return "-"
    return spec.format(measured - doc)


def print_tables(results):
    ident = identity()
    print()
    print("=" * 78)
    print("TILE-SLACK A/B - MEASURED")
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
    print()
    for clip in CLIPS:
        r = results.get((clip, 0.0))
        if r and r.get("status") == "ok":
            print(f"{CLIPS[clip]['label']:<12} {CLIPS[clip]['src'].name}  "
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

    print()
    print("=" * 78)
    print("THE DOCUMENT'S TABLE, FOR COMPARISON")
    print("=" * 78)
    print(DOC_SOURCE)
    print()
    print(head)
    print("|:--|--:|:--|--:|--:|--:|")
    for clip in CLIPS:
        for slack in ARMS:
            d = DOC[(clip, slack)]
            print(f"| {CLIPS[clip]['label']} | {slack:.1f} | {d['rungs']} "
                  f"| {d['util']:.3f} | {d['psnr4']:.2f} | {d['band']:.3f} |")

    print()
    print("=" * 78)
    print("MEASURED MINUS DOCUMENT")
    print("=" * 78)
    print("| clip | slack | rungs taken | stream util | local (4x4) PSNR "
          "| banding index |")
    print("|:--|--:|:--|--:|--:|--:|")
    for clip in CLIPS:
        for slack in ARMS:
            r = results.get((clip, slack))
            d = DOC[(clip, slack)]
            lab = CLIPS[clip]["label"]
            if not r or r.get("status") != "ok":
                print(f"| {lab} | {slack:.1f} | - | - | - | - |")
                continue
            same = (r["rungs_taken"] == d["rungs"])
            print(f"| {lab} | {slack:.1f} | "
                  f"{'SAME' if same else 'DIFFERENT'} "
                  f"| {delta(r['report']['stream_utilization'], d['util'])} "
                  f"| {delta(r['psnr_4x4'], d['psnr4'], '{:+.2f}')} "
                  f"| {delta(r['banding_index'], d['band'])} |")

    print()
    print("=" * 78)
    print("WHAT EACH COLUMN IS, AND HOW FAR TO TRUST THE COMPARISON")
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
        "banding index     RECOMPUTED, NOT RECOVERED. The estimator behind the\n"
        "                  document's column was never published. This is the\n"
        "                  recorded DEFINITION (per-line residual coefficient\n"
        "                  of variation) implemented post-hoc from decoded\n"
        "                  frames - see banding_index() in this file for the\n"
        "                  exact arithmetic. Read the arm-to-arm direction and\n"
        "                  ratio; do NOT read the absolute value as the\n"
        "                  document's quantity.")
    print()
    print("Supporting figures the document's table does not carry:")
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
    # cost line and any gate WARNING are operational facts that no column
    # of the document's table carries, and the at-capacity warning in
    # particular is a reason to distrust an arm's picture on hardware
    # whatever its metrics say.
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
                    warned.append((CLIPS[clip]["label"], slack))
    if warned:
        print()
        for lab, slack in warned:
            print(f"NOTE: {lab} at slack {slack:.1f} tripped the encoder's "
                  f"own gate message above.")
        print("An at-capacity encode is not a picture verdict, but it is a "
              "reason to watch")
        print("that arm for JUDDER and audio breakup specifically (run "
              "sheet, leg 3), and")
        print("the predecessor card DISCARDED such a pair and re-encoded "
              "both arms at a")
        print("lower pinned budget rather than compare across it "
              "(sp14a-task-4-report.md")
        print("section 43.6). Whether to do that here is a ruling, not a "
              "measurement.")

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
