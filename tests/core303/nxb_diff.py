"""Timed-routine diff between two revisions, and the NXB row allow-list.

Usage: python tests/core303/nxb_diff.py [--baseline REV] [--other REV] [--write DIR]

Each revision is extracted with `git archive <rev> src` (no worktree) into
tests/out/core303-rev/<hash>/ and assembled as Release with --lst. The timed
lines are chosen by tests/check_quiet_decode.py's TimedSet over that
revision's own sources. A routine is SAME when its byte-emitting statements
(comments stripped) and byte counts are identical in order; the checker's
file:line key is not used, because line numbers shift between revisions.
"""
import argparse
import contextlib
import io
import re
import subprocess
import sys
import tarfile
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_quiet_decode as cqd  # noqa: E402
import parse  # noqa: E402

REV_DIR = ROOT / "tests" / "out" / "core303-rev"
BASELINE_REV = "afc0dfd"
BASELINE_LOG = "NXBENCH-Q.TXT"
RESULTS = Path(__file__).resolve().parent / "results" / "baseline-old-core-2026-09-17"

# Constants that steer the measured path without changing assembled bytes
# (the byte-count rule cannot see them). nextdaad.inc.
PATH_EQUS = ("NXV2_COPY_DMA_MIN", "NXV2_RUN_DMA_MIN", "NXV2_DMA_CHUNK")

# Row fields: tag, opcode, count, ops per rep, reps, thr, geo
# (video.asm:5098 NXBROW, row layout :3798). nxb_run_table :4080 runs
# each row through the shipping loop (nxb_ops_body :4318 -> vid_next).
NXBROW = re.compile(
    r'^\s*NXBROW\s+"(\w{4})"\s*,\s*(\w+)\s*,\s*([^,]+),\s*([^,]+),\s*([^,]+),'
    r'\s*([^,]+),\s*([^\s;]+)')
EQU = re.compile(r"^(\w+)\s+equ\s+([^;]+?)\s*(?:;|$)", re.I)

# im2_isr runs in every standalone row alike, under 1% of it (video.asm:3947-3951):
# a disclosed constant load, so not mapped. ISR_IN_ROWS adds it to every row.
ISR_IN_ROWS = False
ISR = ["im2_isr"]
# Every row: vid_stub :56, vid_next :264, vid_op_fend :1226 -> vid_term_exit :1235.
DISPATCH = ["vid_stub", "vid_next", "vid_next_fetch", "vid_op_fend",
            "vid_term_exit"]
# Kernels: CPU fill :99, LDI :138, DMA fill :1505, DMA copy :1530, arms :1553-:1576.
FILL_CPU = ["vid_fill_cpu", "vid_fill_blk", "vid_fill_done"]
FILL_DMA = ["vid_fill_dma", "vidDmaFiArm", "vidDmaWr1Inc"]
COPY_CPU = ["vid_copy_ldi", "vid_ldi_blk"]
COPY_DMA = ["vid_copy_dma", "vidDmaCpArm"]
CHUNK_CAP = 240             # NXV2_DMA_CHUNK: DMA only when count >= thr and thr <= 240
OPC = {
    "VOP_SKIP8": ("skip", 8), "VOP_SKIP16": ("skip", 16),
    "VOP_RUN8": ("run", 8), "VOP_RUN16": ("run", 16),
    "VOP_COPY8": ("copy", 8), "VOP_COPY16": ("copy", 16),
    "NXB_OPC_CAL": ("cal", 0),
}


def _num(text):
    t = text.strip()
    return int(t[1:], 16) if t.startswith("$") else int(t, 0)


def row_routines(opc, count, thr, geo):
    """Timed routines a table row runs; thr is the effective select."""
    kind, width = OPC[opc]
    if kind == "cal":
        return []
    # geo (nxb_geo_setup :4177): bit 0 gapped picks vg_/_gap routines; bits 5:4
    # nonzero = dest starts near the edge or seam (vid_dst_next :1095).
    gapped, dest = geo & 1, (geo >> 4) & 3
    sfx = "gap" if gapped else "flat"
    out = list(DISPATCH)
    # 8-bit handlers vf_op_* :191-:231, vg_op_* :360-:454; 16-bit vid_op_*16 :511-:532.
    if width == 8:
        out.append(("vg_op_" if gapped else "vf_op_") + kind + "8")
    else:
        out.append("vid_op_%s16" % kind)
    # Bodies :624/:650/:682: 8-bit only when count >= thr, gapped or dest (superset).
    body = width == 16 or gapped or dest or (kind != "skip" and count >= thr)
    if kind == "skip":
        if body:
            out += ["vid_skip_body", "vid_dst_norm_" + sfx,
                    "vid_chunk_dst_nocap_" + sfx]
    else:
        dma = thr <= CHUNK_CAP and count >= thr
        cpu = count < thr or gapped or dest or count > CHUNK_CAP   # a chunk can be < thr
        if body:
            out += ["vid_%s_body" % kind, "vid_dst_norm_" + sfx,
                    "vid_chunk_dst_" + sfx]
            if kind == "copy":
                out.append("vid_chunk_all")
            if dest and not gapped:
                out.append("vid_chunk_dst_nocap_flat")
        if kind == "run":
            out += (FILL_CPU if cpu or not body else []) + (FILL_DMA if dma else [])
        else:
            out += (COPY_CPU if cpu or not body else []) + (COPY_DMA if dma else [])
    if dest:
        out.append("vid_dst_next")
    if ISR_IN_ROWS:
        out += ISR
    return sorted(set(out))


def _git(*args, binary=False):
    r = subprocess.run(["git", *args], cwd=ROOT, capture_output=True)
    if r.returncode:
        raise RuntimeError("git %s: %s" % (" ".join(args), r.stderr.decode()))
    return r.stdout if binary else r.stdout.decode().strip()


@lru_cache(maxsize=None)
def resolve(rev):
    return _git("rev-parse", "--verify", rev + "^{commit}")


def extract(rev):
    """Extract <rev>'s src/ into tests/out/core303-rev/<hash>/ (kept)."""
    full = resolve(rev)
    d = REV_DIR / full
    if not (d / "src" / "main.asm").is_file():
        d.mkdir(parents=True, exist_ok=True)
        data = _git("archive", full, "src", binary=True)
        with tarfile.open(fileobj=io.BytesIO(data)) as tf:
            tf.extractall(d, filter="data")
    return d


@contextlib.contextmanager
def _tree(tree):
    saved = cqd.SRC_ROOT, cqd.OUT
    cqd.SRC_ROOT, cqd.OUT = tree, tree / "out"
    try:
        yield
    finally:
        cqd.SRC_ROOT, cqd.OUT = saved


@lru_cache(maxsize=None)
def _listing(full):
    """routine -> [(byte count, statement)], plus TimedSet problems."""
    tree = extract(full)
    nex = cqd.NEX
    keep = nex.read_bytes() if nex.exists() else None
    with _tree(tree):
        try:
            ts = cqd.TimedSet()
            lst, _ = cqd.build("release")
            rows = cqd.select(cqd.parse_listing(lst), ts)
        finally:
            if keep is not None and nex.read_bytes() != keep:
                nex.write_bytes(keep)
        names = [n for names in cqd.TIMED.values() for n in names]
        names += [n for _, n, *_ in cqd.TIMED_SPANS]
        by = {n: [] for n in names}
        for f, n, count, src, _ in rows:
            owner = ts.scans[f]["owner"][n]
            if owner in by:
                by[owner].append((count, cqd.statement(src)))
        return by, tuple(ts.problems)


def nxb_diff(rev_a, rev_b):
    """Timed routine -> True when identical in both revisions."""
    a, _ = _listing(resolve(rev_a))
    b, _ = _listing(resolve(rev_b))
    return {n: a[n] == b[n] for n in a}


def _equs(rev):
    text = _git("show", "%s:src/nextdaad.inc" % resolve(rev))
    out = {}
    for line in text.splitlines():
        m = EQU.match(line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def _table_rows(rev):
    text = _git("show", "%s:src/video.asm" % resolve(rev))
    rows = {}
    for line in text.splitlines():
        m = NXBROW.match(line)
        if m:
            rows[m.group(1)] = tuple(x.strip() for x in m.groups()[1:])
    return rows


def _eff_thr(row, equs):
    opc, _, _, _, thr, _ = row
    kind = OPC[opc][0]
    num = _num(thr)
    if kind == "copy":
        return num or _num(equs["NXV2_COPY_DMA_MIN"])
    if kind == "run":
        return num or _num(equs["NXV2_RUN_DMA_MIN"])
    return num


def nxb_allow(rev_a, rev_b, log):
    """Table-row tags of `log` whose row spec, effective select, path
    constants and measured routines are all unchanged between the revisions.
    Returns (allowed tags, {tag: reason} for the rest)."""
    same = nxb_diff(rev_a, rev_b)
    ea, eb = _equs(rev_a), _equs(rev_b)
    ra, rb = _table_rows(rev_a), _table_rows(rev_b)
    changed_equs = [k for k in PATH_EQUS if ea.get(k) != eb.get(k)]
    tags = []
    for run in parse.parse_nxb(log):
        if run.kind == "table" and run.tag not in tags:
            tags.append(run.tag)
    allowed, why = [], {}
    for tag in tags:
        if tag not in ra or tag not in rb:
            why[tag] = "row not in both revisions"
        elif ra[tag] != rb[tag]:
            why[tag] = "row fields differ"
        else:
            row = ra[tag]
            opc, count, _, _, thr, geo = row
            if _eff_thr(row, ea) != _eff_thr(row, eb):
                why[tag] = "effective select differs"
                continue
            routines = row_routines(opc, _num(count), _eff_thr(row, ea), _num(geo))
            bad = [r for r in routines if not same[r]]
            if bad:
                why[tag] = "routines changed: " + ",".join(bad)
            elif changed_equs and OPC[opc][0] != "skip" and \
                    "NXV2_DMA_CHUNK" in changed_equs:
                why[tag] = "NXV2_DMA_CHUNK differs"
            else:
                allowed.append(tag)
    return allowed, why


def routine_diff_text(rev_a, rev_b):
    same = nxb_diff(rev_a, rev_b)
    lines = ["%s %s" % (n, "SAME" if s else "CHANGED") for n, s in same.items()]
    lines.append(
        "aud_dbg_snap sits on im2_isr's audEnable != 0 path, pinned COLD in"
        " tests/check_quiet_decode.py:158-160 (never taken in a session), so"
        " the DEBUG ISR addition is 0 T in every NXB row while the quiet"
        " check passes.")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--baseline", default=BASELINE_REV)
    ap.add_argument("--other", default="main")
    ap.add_argument("--write", help="folder for routine-diff.txt and allow.txt")
    a = ap.parse_args()
    text = routine_diff_text(a.baseline, a.other)
    allowed, why = nxb_allow(a.baseline, a.other, RESULTS / BASELINE_LOG)
    print(text, end="")
    print("allowed %d, excluded %d" % (len(allowed), len(why)))
    for tag, reason in why.items():
        print("  %s: %s" % (tag, reason))
    if a.write:
        d = Path(a.write)
        (d / "routine-diff.txt").write_text(text, encoding="ascii", newline="\n")
        (d / "allow.txt").write_text("".join(t + "\n" for t in allowed),
                                     encoding="ascii", newline="\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
