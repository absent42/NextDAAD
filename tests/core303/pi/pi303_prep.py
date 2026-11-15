"""P2 frame preparation bench: JPEG decode, RGB to RRRGGGBB, span extraction, raw read.
Needs no Next and no SPI. Writes PREP.LOG; the C rows (impl=1) come from c/prep303.c.
"""
import argparse
import io
import os
import shutil
import subprocess
import sys
import tempfile
import time

import numpy as np
from PIL import Image

from bundle import bundle_hash
from pilog import PiLogWriter

TOOL = "pi303_prep"
HERE = os.path.dirname(os.path.abspath(__file__))
FRAME_BYTES = 49152
GAP = 4                     # equal bytes between differing ones that still merge: under 4
BUCKETS = (1, 2, 4, 8, 16, 64, 256)
JPEGLIB = "/usr/include/jpeglib.h"

_LUT_R = (np.arange(256) & 0xE0).astype(np.uint8)
_LUT_G = ((np.arange(256) & 0xE0) >> 3).astype(np.uint8)
_LUT_B = (np.arange(256) >> 6).astype(np.uint8)


def convert(rgb):
    return _LUT_R[rgb[..., 0]] | _LUT_G[rgb[..., 1]] | _LUT_B[rgb[..., 2]]


def span_lens(prev, cur):
    """Lengths of the differing runs, gaps of fewer than GAP equal bytes merged."""
    idx = np.flatnonzero(prev.ravel() != cur.ravel())
    if idx.size == 0:
        return np.zeros(0, dtype=np.int64)
    cut = np.flatnonzero(np.diff(idx) > GAP)
    starts = np.concatenate(([idx[0]], idx[cut + 1]))
    ends = np.concatenate((idx[cut], [idx[-1]]))
    return ends - starts + 1


def _bucket(n):
    for b in reversed(BUCKETS):
        if n >= b:
            return b
    return 1


def build_c(work):
    """Compile prep303.c with the local gcc, with libjpeg when jpeglib.h exists; else None."""
    gcc = shutil.which("gcc")
    if not gcc:
        return None
    exe = os.path.join(work, "prep303")
    src = [os.path.join(HERE, "c", "prep303.c"), os.path.join(HERE, "c", "core303pi.c")]
    base = [gcc, "-O2", "-I" + os.path.join(HERE, "c"), "-o", exe] + src
    tries = [base + ["-ljpeg"]] if os.path.isfile(JPEGLIB) else []
    tries.append(base + ["-DNO_JPEG"])
    for cmd in tries:
        if subprocess.run(cmd, capture_output=True).returncode == 0:
            return exe
    return None


def _c_rows(exe, fdir, rdir, n):
    """Run prep303; returns (rows, skips) parsed from its stdout, or None on failure."""
    try:
        r = subprocess.run([exe, fdir, rdir, str(n)], capture_output=True, text=True)
    except OSError:
        return None
    if r.returncode != 0:
        return None
    rows, skips = [], []
    for ln in r.stdout.splitlines():
        if ln.startswith("#SKIP "):
            _, tag, reason = ln.split(" ", 2)
            skips.append((tag, reason))
        elif ln:
            tok = ln.split(" ")
            rows.append((tok[0], {k: int(v) for k, v in (t.split("=") for t in tok[1:])}))
    return rows, skips


def _read(path):
    with open(path, "rb") as f:
        return f.read()


def main(frames_dir, out_dir, bundle, c_prep=None, clock=time.perf_counter_ns):
    """c_prep: path of a built prep303; None builds it with gcc; "" runs without it."""
    names = sorted(f[:-4] for f in os.listdir(frames_dir) if f.endswith(".jpg"))
    n = len(names)
    log = PiLogWriter(os.path.join(out_dir, "PREP.LOG"), TOOL, bundle)
    work = tempfile.mkdtemp(prefix="p303prep")
    try:
        t_jd = 0
        decoded = []
        for nm in names:
            data = _read(os.path.join(frames_dir, nm + ".jpg"))    # file I/O outside the timer
            t0 = clock()
            with Image.open(io.BytesIO(data)) as im:
                im.load()
                rgb = im.convert("RGB")
            t_jd += clock() - t0
            decoded.append(np.asarray(rgb))
        log.row("P2JD", ns=t_jd, frames=n, impl=0)
        t0 = clock()
        conv = [convert(a) for a in decoded]
        log.row("P2CV", ns=clock() - t0, frames=n, impl=0)
        t0 = clock()
        lens = [span_lens(conv[i - 1], conv[i]) for i in range(1, n)]
        t_sp = clock() - t0
        spans = sum(int(x.size) for x in lens)
        log.row("P2SP", ns=t_sp, frames=max(n - 1, 0), impl=0, spans=spans)
        t0 = clock()
        for nm in names:
            _read(os.path.join(frames_dir, nm + ".raw"))
        log.row("P2RD", ns=clock() - t0, frames=n)
        hist = dict(("b%d" % b, 0) for b in BUCKETS)
        for x in lens:
            for v in x.tolist():
                hist["b%d" % _bucket(v)] += 1
        log.row("P2SH", **hist)

        exe = build_c(work) if c_prep is None else (c_prep or None)
        res = None
        if exe:
            for i, a in enumerate(decoded):
                with open(os.path.join(work, "F%03d.rgb" % i), "wb") as f:
                    f.write(a.tobytes())
            res = _c_rows(exe, frames_dir, work, n)
        if res is None:
            why = "CFAIL" if exe else "NOCC"       # a C tool that exists but failed
            log.skip("P2JD", why if exe or os.path.isfile(JPEGLIB) else "NOHDR")
            log.skip("P2CV", why)
            log.skip("P2SP", why)
        else:
            for tag, kv in res[0]:
                log.row(tag, **kv)
            for tag, reason in res[1]:
                log.skip(tag, reason)
        return 0
    finally:
        log.close()
        shutil.rmtree(work, ignore_errors=True)


def cli(argv=None):
    ap = argparse.ArgumentParser(prog=TOOL)
    ap.add_argument("--frames", required=True)
    ap.add_argument("--out", default=".")
    ap.add_argument("--bundle", default=None)
    a = ap.parse_args(argv)
    return main(a.frames, a.out, a.bundle or bundle_hash(HERE))


if __name__ == "__main__":
    sys.exit(cli())
