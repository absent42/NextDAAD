#!/usr/bin/env python3
"""tests/check_quiet_decode.py - prove the NXB_QUIET DEBUG image executes
Release's instructions on every timed video path.

Assembles Release and quiet DEBUG (DEBUG + NXB_QUIET) with sjasmplus --lst
into tests/out/quiet-check/. Inside the timed set (TIMED, TIMED_SPANS), with
the COLD DEBUG blocks skipped, the sequence of assembled source lines that
emit bytes (file, line) and their byte counts must be identical. Operand
values may differ; ALIGN lines compare by presence (their padding follows the
address). Nothing outside the timed set is compared.

COLD entries are anchored by enclosing label and statements, and resolved to
line ranges on every run (--list prints them), so line shifts need no edit.
A stale entry only prints a note: its block is then compared, never skipped.

Exit 0 = OK. Exit 1 = a difference (file, line, both byte counts) or a build
or listing failure. build/nextdaad.nex is saved first and restored on exit.
"""
import argparse
import difflib
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SJASM = ROOT / "tools" / "sjasmplus" / "sjasmplus.exe"
OUT = ROOT / "tests" / "out" / "quiet-check"
NEX = ROOT / "build" / "nextdaad.nex"

# Defines mirror build.ps1: Release none, -BenchQuiet = DEBUG + NXB_QUIET.
FLAVOURS = {
    "release": [],
    "quiet": ["-DDEBUG=1", "-DNXB_QUIET=1"],
}

# Routines on a sitting-5 timed path: global label to the next global label.
# Fault routines vid_op_bad, vid_dec_abort and vid_dec_abort_pos are excluded.
TIMED = {
    "src/video.asm": [
        # dispatch, kernels, fast handlers
        "vid_stub", "vid_fill_cpu", "vid_fill_blk", "vid_fill_done",
        "vid_copy_ldi", "vid_ldi_blk",
        "vf_op_skip8", "vf_op_run8", "vf_op_copy8", "vf_edge_relay",
        "vf_bad_relay", "vid_next", "vid_next_fetch", "vid_op_edge",
        "vg_op_skip8", "vg_op_run8", "vg_edge_relay", "vg_bad_relay",
        "vg_op_copy8", "vid_op_skip16", "vid_op_run16", "vid_op_copy16",
        "vid_slow_op", "vid_fetch", "vid_fetch_ram",
        # chunked bodies, sizing, seam walkers
        "vid_skip_body", "vid_run_body", "vid_copy_body",
        "vid_dst_norm_gap", "vid_dst_norm_flat", "vid_chunk_all",
        "vid_chunk_dst_flat", "vid_chunk_dst_gap", "vid_chunk_dst_nocap_gap",
        "vid_chunk_dst_nocap_flat", "vid_chunk_src", "vid_src_next",
        "vid_dst_next",
        # operand-less ops and the terminal tail
        "vid_op_pal", "vid_op_kstart", "vid_op_kflip", "vid_op_fend",
        "vid_term_exit", "vid_dec_done", "vid_bound_chk", "vid_dec_done_strm",
        "vid_depth_debit", "vid_rl_mod", "vid_pos24",
        # zxnDMA kernels and their arm programs
        "vid_fill_dma", "vid_copy_dma", "vidDmaFiArm", "vidDmaWr1Inc",
        "vidDmaCpArm",
        # frame decode entry
        "vid_decode_frame", "vid_decode_any", "vid_dst_setup", "vid_dst_base",
        "vid_decode_frame_ds", "vid_src_seek",
        # audio feed and pacing
        "vid_aud_stage", "vid_pace_poll", "vid_aud_pump",
        # frame loop callees, audio ISR
        "vid_pal_present", "vid_key_any", "video_ctc_isr_stereo",
        # ring gate and streaming producer
        "vid_ring_gate", "vid_run_walk_h", "vid_prod_step", "vid_next_run_h",
        "vid_win_open_h", "vid_win_close_h", "vid_card_desel_h",
        "vid_sd_cmd_np_h", "vid_sd_cmd_h", "vid_sd_tok_h", "vid_sd_blk_h",
        "vid_mf_disable_h", "vid_mf_restore_h", "vid_loop_rewind",
        # direct-serve transport
        "vid_ds_next", "vid_ds_byte", "vid_ds_blkopen", "vid_ds_pad",
        "vid_ds_xfer", "vid_ds_iblk", "vid_ds_copy_body", "vid_ds_pal",
        "vid_ds_done",
    ],
    "src/hardware.asm": ["nr_read"],        # vid_mf_disable_h
    "src/interrupts.asm": ["im2_isr"],      # the frame ISR (audEnable = 0)
}

# (file, routine, start local label, end statement inclusive)
TIMED_SPANS = [
    ("src/video.asm", "vid_run", ".frameloop", "jp nz, .frameloop"),
]

# Every COLD top-level IFDEF DEBUG block: (file, enclosing global label,
# anchor statements, reason). The anchor is the block's whole statement list,
# else a contiguous run inside it; it must pick exactly one block.
COLD = [
    ("src/video.asm", "vid_op_bad", ("ld (vidErrOp), a",),
     "fault: reserved opcode, ERR=OP breadcrumb"),
    ("src/video.asm", "vid_dec_abort", ("call vid_pos24",),
     "fault: POS= breadcrumb"),
    ("src/video.asm", "vid_dec_abort_pos", ("call nxb_reclaim",),
     "fault: ERR= store and bench reclaim"),
    ("src/video.asm", "vid_dst_norm_flat", ("vid_rl_poll:",),
     "definitions of vid_rl_poll/vid_play_frame/vid_play_close; timed "
     "call sites are wrapped, teardown still calls vid_play_close"),
    ("src/video.asm", "vid_dec_done", ("ld (vidErrPos), hl",),
     "fault: .ovr bound-trip breadcrumb"),
    ("src/video.asm", "vid_depth_debit", ("ld a, (vidDepthClip)",),
     "never taken: a depth clamp is a bookkeeping bug"),
    ("src/video.asm", "vid_play", ("call nz, nxb_ds_unsel",),
     "open verdict, pre-arm"),
    ("src/video.asm", "vid_run", ("ld (nxbSvTm3), a",),
     "orchestration: pre-borrow MMU3 capture, pre-arm"),
    ("src/video.asm", "vid_run", ("call nz, nxb_ds_unsel",),
     "orchestration: failed-open bail"),
    ("src/video.asm", "vid_run", ("call nxb_ds_rows",),
     "bench hook dispatch, pre-arm"),
    ("src/video.asm", "vid_run", ("ld hl, vidLoopPass",),
     "EOF pass breadcrumb, past the per-frame loop-back jump"),
    ("src/video.asm", "vid_run", ("call vid_play_close",),
     "teardown: PLAY= bracket close"),
    ("src/video.asm", "vid_run", ("call vid_tl_report",),
     "report after teardown"),
    ("src/video.asm", "vidSvHook", ("vid_tl_report:",),
     "report cells, report hop and the NXB bench"),
    ("src/video.asm", "nxv2_open_body", ("ld (vidFillT0), hl",),
     "open: FILL= start stamp"),
    ("src/video.asm", "nxv2_open_body", ("ld (vidSnapCntL), a",),
     "open: SNAP= mirror"),
    ("src/video.asm", "nxv2_open_body", ("ld (vidNomStepC), hl",),
     "open: NOM= step division"),
    ("src/video.asm", "nxv2_open_body",
     ("ld hl, 0", "ld (vidRingMin + DATA_WINDOW - OVL_ORG), hl"),
     "staging: resident RING= seeds"),
    ("src/video.asm", "nxv2_open_body", ("ld hl, (vidRingCapBlkC)",),
     "staging: streaming RING= min seed"),
    ("src/video.asm", "nxv2_open_body",
     ("ld (vidRingMin + DATA_WINDOW - OVL_ORG), hl", "ld hl, 0"),
     "staging: .handoff RING= seeds"),
    ("src/video.asm", "nxv2_open_body", ("ld hl, 0",),
     "staging: direct RING= min seed"),
    ("src/video.asm", "vid_stage_common",
     ("ld (vidTlFillFrames + DATA_WINDOW - OVL_ORG), hl",),
     "staging: FILL= duration"),
    ("src/video.asm", "vidHdrMarginC", ("vidNomStepC: dw 0",),
     "open-body data cell"),
    ("src/video.asm", "vidEntCntC", ("vidFillT0: dw 0",),
     "open-body data cell"),
    ("src/video.asm", "vid_run_orch_body", ("call vid_open_fail_print",),
     "orchestration: open failure print"),
    ("src/video.asm", "vid_run_l2setup_body",
     ("ld (vidNomStep+DATA_WINDOW-OVL_ORG), hl",),
     "session init: report cell baseline, pre-arm"),
    ("src/video.asm", "vid_snap_save_body", ("vid_chk_surface:",),
     "snapshot: CHK= surface sum"),
    ("src/video.asm", "vid_snap_restore_body", ("call vid_chk_surface",),
     "snapshot restore, post-disarm"),
    ("src/video.asm", "vid_open_video_body", ("call vid_play_missing_print",),
     "open fault print"),
    ("src/video.asm", "vid_open_video_body", ("vid_play_missing_print:",),
     "open fault print routines"),
    ("src/video.asm", "vid_read_block", ("DUP 64",),
     "staging: callers are the pre-arm load, prefill and direct header read"),
    ("src/video.asm", "vidStrmBlkBuf", ("vid_tl_report_body:",),
     "report body"),
    ("src/interrupts.asm", "im2_isr", ("call aud_dbg_snap",),
     "audEnable != 0 path, never taken in a session"),
]

LST_ROW = re.compile(r"^\s*(\d+)\+*\s*([0-9A-F]{4})(?: (.*))?$")
LABEL = re.compile(r"^([A-Za-z_]\w*):")
COND_OPEN = {"IF", "IFN", "IFDEF", "IFNDEF", "IFUSED", "IFNUSED"}


class Fail(Exception):
    pass


def rel(path):
    """Listing or source path -> repo-relative posix path."""
    p, r = os.path.abspath(path), str(ROOT) + os.sep
    if os.path.normcase(p).startswith(os.path.normcase(r)):
        return p[len(r):].replace(os.sep, "/")
    return p


def statement(line):
    """Source line without its comment, whitespace collapsed."""
    out, quote = [], None
    for ch in line:
        if quote:
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == ";":
            break
        out.append(ch)
    return " ".join("".join(out).split())


# ------------------------------------------------------------- source side

def scan_source(relpath):
    """Global labels outside conditionals and top-level IFDEF DEBUG blocks."""
    lines = (ROOT / relpath).read_text(encoding="utf-8").split("\n")
    labels, blocks, depth, owner, cur = [], [], 0, None, None
    for n, line in enumerate(lines, 1):
        st = statement(line)
        word = st.split(" ")[0].upper() if st else ""
        m = LABEL.match(line)
        if m and depth == 0:
            labels.append((m.group(1), n))
            owner = m.group(1)
        if word in COND_OPEN:
            if depth == 0 and st.upper() == "IFDEF DEBUG":
                cur = {"start": n, "owner": owner, "stmts": []}
            depth += 1
            continue
        if word == "ENDIF":
            depth -= 1
            if depth < 0:
                raise Fail(f"{relpath}:{n}: unbalanced ENDIF")
            if depth == 0 and cur:
                cur["end"] = n
                blocks.append(cur)
                cur = None
            continue
        if cur is not None and st and word not in ("ELSE", "ELSEIF"):
            cur["stmts"].append(st)
    return lines, labels, blocks


def label_range(relpath, scan, name):
    """Global label line to the line before the next global label."""
    lines, labels, _ = scan
    hits = [i for i, (lab, _) in enumerate(labels) if lab == name]
    if len(hits) != 1:
        raise Fail(f"{relpath}: timed label {name} found {len(hits)} times")
    i = hits[0]
    end = labels[i + 1][1] - 1 if i + 1 < len(labels) else len(lines)
    return labels[i][1], end


def timed_ranges():
    """{file: [(start, end, name)]} for TIMED and TIMED_SPANS."""
    out, scans = {}, {}
    files = set(TIMED) | {f for f, *_ in TIMED_SPANS}
    for f in files:
        scans[f] = scan_source(f)
    for f, names in TIMED.items():
        for name in names:
            a, b = label_range(f, scans[f], name)
            out.setdefault(f, []).append((a, b, name))
    for f, name, start, stop in TIMED_SPANS:
        lines = scans[f][0]
        a, b = label_range(f, scans[f], name)
        s = next((n for n in range(a, b + 1)
                  if re.match(re.escape(start) + r"\b", lines[n - 1])), None)
        e = next((n for n in range(s or a, b + 1)
                  if statement(lines[n - 1]) == stop), None)
        if s is None or e is None:
            raise Fail(f"{f}: span {name}{start} .. '{stop}' not found")
        out.setdefault(f, []).append((s, e, f"{name}{start}"))
    return out, scans


def cold_ranges(scans, notes):
    """{file: [(start, end, label, reason)]} for the COLD entries that resolve."""
    out = {}
    for f, owner, anchor, reason in COLD:
        if f not in scans:
            scans[f] = scan_source(f)
        blocks = [b for b in scans[f][2] if b["owner"] == owner]
        hits = [b for b in blocks if tuple(b["stmts"]) == anchor]
        if not hits:
            k = len(anchor)
            hits = [b for b in blocks
                    if any(tuple(b["stmts"][i:i + k]) == anchor
                           for i in range(len(b["stmts"]) - k + 1))]
        if len(hits) != 1:
            notes.append(f"note: COLD entry {f} {owner} {anchor[0]!r} matches "
                         f"{len(hits)} blocks - not skipped")
            continue
        out.setdefault(f, []).append((hits[0]["start"], hits[0]["end"],
                                      owner, reason))
    return out


# ------------------------------------------------------------ listing side

def build(flavour):
    d = OUT / flavour
    (d / "build").mkdir(parents=True, exist_ok=True)
    lst = d / "nextdaad.lst"
    if lst.exists():
        lst.unlink()
    prefix = d.relative_to(ROOT).as_posix() + "/"
    cmd = [str(SJASM), "--zxnext=cspect", "--msg=war", "--fullpath",
           f"--outprefix={prefix}", f"--lst={lst.relative_to(ROOT).as_posix()}",
           *FLAVOURS[flavour], "src/main.asm"]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0 or not lst.exists():
        tail = (r.stdout + r.stderr).strip().splitlines()[-15:]
        raise Fail(f"{flavour} assembly failed:\n  " + "\n  ".join(tail))
    return lst, d / "build" / "nextdaad.nex"


def parse_listing(lst):
    """Rows (file, line, count, src). count is None on ALIGN lines."""
    raw, files = [], []
    for text in lst.read_text(encoding="utf-8", errors="replace").splitlines():
        if text.startswith("# file opened: "):
            files.append(rel(text[15:]))
            continue
        if text.startswith("# file closed: "):
            files.pop()
            continue
        m = LST_ROW.match(text)
        if not m:
            if text.strip():
                raise Fail(f"{lst.name}: unrecognised listing row: {text[:60]}")
            continue
        rest = m.group(3) or ""
        raw.append([files[-1], int(m.group(1)), int(m.group(2), 16),
                    rest[:12], rest[12:13], rest[13:]])
    rows = []
    for i, (f, n, addr, field, flag, src) in enumerate(raw):
        if field.startswith("~"):
            continue
        if statement(src).split(" ")[0].upper() == "ALIGN":
            rows.append((f, n, None, src))
            continue
        if "..." in field:
            nxt = raw[i + 1][2] if i + 1 < len(raw) else addr
            count = (nxt - addr) & 0xFFFF
        else:
            count = len(re.findall(r"\b[0-9A-F]{2}\b", field))
        if not count:
            continue
        # a data line over 4 bytes continues on rows with no source text
        if not src.strip() and flag != ">" and rows and rows[-1][:2] == (f, n) \
                and rows[-1][2] is not None:
            rows[-1] = (f, n, rows[-1][2] + count, rows[-1][3])
            continue
        rows.append((f, n, count, src))
    return rows


def select(rows, timed, cold):
    def inside(f, n, spans):
        return any(a <= n <= b for a, b, *_ in spans.get(f, ()))
    return [r for r in rows if inside(r[0], r[1], timed)
            and not inside(r[0], r[1], cold)]


# ------------------------------------------------------------------ compare

def compare(a_name, a, b_name, b):
    """Print each differing line with both byte counts; return the count."""
    def show(c):
        return "ALIGN" if c is None else f"{c} B"
    ka, kb = [r[:2] for r in a], [r[:2] for r in b]
    diffs = []
    sm = difflib.SequenceMatcher(None, ka, kb, autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "equal":
            for ra, rb in zip(a[i1:i2], b[j1:j2]):
                if ra[2] != rb[2]:
                    diffs.append((ra[0], ra[1], show(ra[2]), show(rb[2]), ra[3]))
            continue
        # a line missing on one side assembled 0 bytes there
        agg = {}
        for side, part in ((0, a[i1:i2]), (1, b[j1:j2])):
            for f, n, c, src in part:
                e = agg.setdefault((f, n), [0, 0, src])
                e[side] = None if c is None else (e[side] or 0) + c
        region = [(f, n, show(ca), show(cb), src)
                  for (f, n), (ca, cb, src) in agg.items() if ca != cb]
        if not region:
            f, n = (ka[i1:i2] or kb[j1:j2])[0]
            region = [(f, n, "-", "-", "line order differs")]
        diffs += region
    for f, n, ca, cb, src in diffs:
        print(f"DIFF {f}:{n}: {a_name} {ca}, {b_name} {cb} | {src.strip()}")
    return len(diffs)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def run(args, built):
    notes = []
    timed, scans = timed_ranges()
    cold = cold_ranges(scans, notes)
    if args.list:
        for f, spans in timed.items():
            for a, b, name in spans:
                print(f"TIMED {f}:{a}-{b} {name}")
        for f, spans in cold.items():
            for a, b, owner, reason in spans:
                used = any(x <= b and a <= y for x, y, _ in timed.get(f, ()))
                tag = " (inside the timed set)" if used else ""
                print(f"COLD  {f}:{a}-{b} {owner}: {reason}{tag}")
    sel = {}
    for flavour in ("release", "quiet"):
        lst, nex = build(flavour)
        built.add(sha(nex))
        sel[flavour] = select(parse_listing(lst), timed, cold)
        print(f"{flavour:8} {nex.relative_to(ROOT).as_posix()} sha256 {sha(nex)}")
    for note in notes:
        print(note)
    rows_r = sel["release"]
    empty = [(f, name) for f, spans in timed.items() for a, b, name in spans
             if not any(r[0] == f and a <= r[1] <= b for r in rows_r)]
    for f, name in empty:
        print(f"FAIL {f}: timed range {name} assembles no bytes in release")
    ndiff = compare("release", rows_r, "quiet", sel["quiet"])
    nbytes = sum(r[2] or 0 for r in rows_r)
    skipped = sum(1 for f, spans in cold.items() for a, b, *_ in spans
                  if any(x <= b and a <= y for x, y, _ in timed.get(f, ())))
    print(f"timed set: {sum(len(s) for s in timed.values())} ranges, "
          f"{len(rows_r)} assembled lines, {nbytes} B; "
          f"{skipped} COLD ranges skipped inside it")
    if ndiff or empty:
        print(f"FAIL: {ndiff} line(s) differ between release and quiet")
        return 1
    print("OK: quiet timed paths are instruction-identical to release")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true",
                    help="print the resolved timed and COLD line ranges")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    saved = NEX.read_bytes() if NEX.exists() else None
    if saved is not None:
        (OUT / "saved-nextdaad.nex").write_bytes(saved)
    built = set()
    try:
        return run(args, built)
    except Fail as e:
        print(f"FAIL: {e}")
        return 1
    finally:
        if saved is not None:
            cur = NEX.read_bytes() if NEX.exists() else None
            if cur != saved:
                if cur is None or hashlib.sha256(cur).hexdigest().upper() in built:
                    NEX.write_bytes(saved)
                    print("restored build/nextdaad.nex")
                else:
                    print("note: build/nextdaad.nex changed during the check "
                          "(not by it) - left as found")


if __name__ == "__main__":
    sys.exit(main())
