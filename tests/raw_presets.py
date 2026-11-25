#!/usr/bin/env python3
"""tests/raw_presets.py - raw --direct gate verdicts behind the kit presets.

python tests\\raw_presets.py [--stall-budget off|measured]

For the six target shapes and the four direct preset shapes the kit shipped
before the raw layout, prints the utilisation of a frame without a palette
(nxv2enc.raw_supply_check) at 25, 16.67 and 12.5 fps in stereo and mono (the
mono priced is sound from the zxnDMA, the form a shipped game plays), the
verdict per form (pass up to 0.90, warn over 0.90, refuse over 1.00), the form
--direct-sound auto picks (nxv2enc.raw_pick_sound), and the card bytes per frame
and MB per second of that form (sound plus pixel sectors; a scene's palette
sector is not counted). Then the tallest height per width, rate and form.
"""
import argparse
import contextlib
import io
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "authoring-kit" / "lib"))

import nxv2enc as enc      # noqa: E402

TARGETS = (((256, 192), 25), ((320, 160), 25), ((320, 192), 25),
           ((280, 224), 25), ((320, 240), 16.67), ((256, 240), 16.67))
OLD_DIRECT = (("full", 12.5), ("16:9", 12.5), ((256, 167), 25), ((320, 105), 25))
TALL_WIDTHS = (256, 280, 320)


def verdict(u):
    if u > 1.0:
        return "refuse"
    return "warn" if u > enc.STREAM_WARN_UTIL else "pass"


def shape_wh(shape):
    return enc.PRESETS[shape] if isinstance(shape, str) else shape


def row(w, h, fps, **kw):
    """One shape and rate: per-form utilisation and verdict, auto pick, bytes."""
    sw, _ = enc.raw_surface(w, h, "auto")
    u = {f: enc.raw_supply_check(w, h, sw, fps, f, **kw)["utilization"] for f in enc.RAW_K}
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            pick, _chk = enc.raw_pick_sound(w, h, sw, fps, "auto", **kw)
    except SystemExit:
        pick = None
    out = dict(w=w, h=h, fps=fps, surface=sw, util=u,
               verdict={f: verdict(x) for f, x in u.items()}, pick=pick)
    if pick:
        snd = enc.audio_layout(fps, 2 if pick == "stereo" else 1, raw=True)[3]
        out["frame_bytes"] = snd + enc.raw_layout(w, h, sw)["sectors"] * 512
        out["mb_s"] = out["frame_bytes"] * fps / 1e6
    return out


def print_rows(title, shapes, **kw):
    print(f"\n{title}")
    print(f"  {'shape':<16}{'surf':>5}{'fps':>7}  {'stereo':>7} {'':<7}{'mono':>7} {'':<7}"
          f"{'auto':<8}{'B/frame':>8}{'MB/s':>7}")
    for shape, target_fps in shapes:
        w, h = shape_wh(shape)
        name = f"{shape} {w}x{h}" if isinstance(shape, str) else f"{w}x{h}"
        for fps in enc.RAW_RATES:
            r = row(w, h, fps, **kw)
            mark = "*" if abs(fps - target_fps) < 1e-9 else " "
            tail = (f"{r['pick']:<8}{r['frame_bytes']:>8}{r['mb_s']:>7.2f}" if r["pick"]
                    else f"{'refused':<8}{'-':>8}{'-':>7}")
            print(f"{mark} {name:<16}{r['surface']:>5}{fps:>7g}  "
                  f"{r['util']['stereo']:>7.4f} {r['verdict']['stereo']:<7}"
                  f"{r['util']['mono']:>7.4f} {r['verdict']['mono']:<7}{tail}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--stall-budget", choices=("off", "measured"), default="off")
    args = ap.parse_args(argv)
    kw = dict(stall_budget=args.stall_budget)
    print(f"raw --direct gate: a frame without a palette over the sound period; "
          f"stall budget {args.stall_budget}; warn over {enc.STREAM_WARN_UTIL:.2f}, "
          f"refuse over 1.00; * = the shape's own rate")
    print_rows("Target shapes", TARGETS, **kw)
    print_rows("Direct preset shapes before the raw layout", OLD_DIRECT, **kw)
    print("\nTallest height (utilisation up to 1.00 / up to 0.90)")
    print(f"  {'width':<7}{'fps':>7}  {'stereo':>9}  {'mono':>9}")
    for w in TALL_WIDTHS:
        for fps in enc.RAW_RATES:
            cells = []
            for f in enc.RAW_K:
                cells.append(f"{enc.raw_max_height(w, 'auto', fps, f, **kw)}/"
                             f"{enc.raw_max_height(w, 'auto', fps, f, util=enc.STREAM_WARN_UTIL, **kw)}")
            print(f"  {w:<7}{fps:>7g}  {cells[0]:>9}  {cells[1]:>9}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
