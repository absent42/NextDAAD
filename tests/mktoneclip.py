#!/usr/bin/env python3
"""tests/mktoneclip.py - the 8 s left/right tone source for the raw sound fixtures.

python tests\\mktoneclip.py --out <file.mp4> [--ffmpeg <ffmpeg.exe>]

Picture: ffmpeg testsrc2 at 25 fps. Sound, stereo, amplitude 0.5: seconds 0-4
a 440 Hz sine on the LEFT channel only, seconds 4-8 an 880 Hz sine on the RIGHT
channel only (both start and stop on a zero crossing). ALAC keeps the silent
channel exactly silent.
"""
import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FFMPEG = ROOT / "tools" / "ffmpeg" / "bin" / "ffmpeg.exe"
AUDIO = ("aevalsrc=exprs='if(lt(t,4),0.5*sin(2*PI*440*t),0)|"
         "if(gte(t,4),0.5*sin(2*PI*880*t),0)':s=48000:d=8:c=stereo")
VIDEO = "testsrc2=size=640x360:rate=25:duration=8"


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--ffmpeg", default=str(FFMPEG))
    a = ap.parse_args(argv)
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [a.ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
           "-f", "lavfi", "-i", VIDEO, "-f", "lavfi", "-i", AUDIO,
           "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "alac",
           "-t", "8", str(out)]
    r = subprocess.run(cmd)
    if r.returncode != 0 or not out.exists():
        print(f"mktoneclip: ffmpeg failed (exit {r.returncode})", file=sys.stderr)
        return 1
    print(f"wrote {out}: {out.stat().st_size} B")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
