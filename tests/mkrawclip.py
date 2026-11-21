#!/usr/bin/env python3
"""tests/mkrawclip.py - write an ungated raw-layout NXV clip (test fixture).

python tests\\mkrawclip.py --src <video> --shape WxH --fps F --channels {1,2}
    [--surface 256|320] [--start T] [--duration S] [--ffmpeg PATH] --out <file.vid>

Goes through nxv2enc._encode_raw(gate=False): no admission gate.
"""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "authoring-kit" / "lib"))

import nxv2enc  # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--src", required=True)
    ap.add_argument("--shape", required=True, help="WIDTHxHEIGHT")
    ap.add_argument("--fps", type=float, default=25.0)
    ap.add_argument("--channels", type=int, choices=(1, 2), default=2)
    ap.add_argument("--surface", choices=("256", "320"), default="auto")
    ap.add_argument("--start", default=None)
    ap.add_argument("--duration", default=None)
    ap.add_argument("--ffmpeg", default=None)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    try:
        w, h = (int(v) for v in a.shape.lower().split("x"))
    except ValueError:
        ap.error("--shape must be WIDTHxHEIGHT")
    nxv2enc.raw_surface(w, h, a.surface)        # validate before extraction
    ex = nxv2enc._extract_source(a.src, w, h, a.fps, a.start, a.duration,
                                 a.ffmpeg, None, raw=True, channels=a.channels)
    rep = nxv2enc._encode_raw(ex, w, h, a.fps, a.out, surface=a.surface,
                              channels=a.channels, gate=False)
    print(f"wrote {a.out}: {rep.total_bytes} B, {rep.frames} frames")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
