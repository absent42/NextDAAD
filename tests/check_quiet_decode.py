#!/usr/bin/env python3
"""tests/check_quiet_decode.py - prove the NXB_QUIET DEBUG image (or, with
--debug, standard DEBUG) executes Release's instructions on every timed video
path. Rules and exit codes: --help."""
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
NEX = ROOT / "build" / "nextdaad.nex"
SRC_ROOT = ROOT                       # --src-root: a copy holding src/
OUT = ROOT / "tests" / "out" / "quiet-check"

HELP = """\
Assembles Release and quiet DEBUG (DEBUG + NXB_QUIET), or with --debug Release
and standard DEBUG, with sjasmplus --lst into tests/out/quiet-check/. In the
lines owned by the timed routines (TIMED, TIMED_SPANS), the sequence of lines
that emit bytes (file, line) and their byte counts must be identical; operand
values may differ. Nothing else is compared.
- A line belongs to the global label above it; a label inside a conditional
  owns lines only to the end of its branch.
- Every global label inside REGIONS must be in TIMED, TIMED_SPANS or EXCLUDED.
- COLD_PINNED blocks are skipped only when their statement list and the
  statement before their IFDEF match exactly; COLD entries are never skipped.
- --debug also skips QUIET_PINNED blocks: each IFNDEF NXB_QUIET block must sit
  directly inside IFDEF DEBUG and match its routine, the statement before
  that IFDEF and its statement list exactly. No other difference is allowed.
- ALIGN compares by presence after an unconditional jp/jr/ret, else by padding.
- Macro and DUP rows also compare their text with numbers masked.
Exit 0 = OK. Exit 1 = a difference, a classification failure or a build
failure. build/nextdaad.nex is saved first and restored on exit."""

# Defines mirror build.ps1: Release none, -BenchQuiet = DEBUG + NXB_QUIET.
FLAVOURS = {
    "release": [],
    "quiet": ["-DDEBUG=1", "-DNXB_QUIET=1"],
    "debug": ["-DDEBUG=1"],
}

# Routines on a sitting-5 timed path. Fault routines are EXCLUDED.
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

# Timed regions: first label to the label after the region (None = EOF).
REGIONS = {
    "src/video.asm": ("vid_stub", "vidLoopMode"),
    "src/hardware.asm": ("nr_read", None),
    "src/interrupts.asm": ("im2_isr", "ctc_isr"),
}

# Global labels inside a region that are not timed.
EXCLUDED = {
    "src/video.asm": [
        "vid_hop2",                                          # cold page hop
        "vid_op_bad", "vid_dec_abort", "vid_dec_abort_pos",  # fault routines
        "vid_rl_poll", "vid_play_frame", "vid_play_close",   # DEBUG-only
        "vid_play",                                          # open, pre-arm
        "vid_run",                                           # TIMED_SPANS only
    ],
}

# COLD blocks inside timed routines: (file, routine, statement before the
# IFDEF, exact statement list, reason). No match fails the check.
COLD_PINNED = [
    ("src/video.asm", "vid_dec_done", "pop af",
     ("ld (vidErrPos), hl", "ld a, b", "ld (vidErrPos+2), a"),
     "fault: .ovr bound-trip breadcrumb"),
    ("src/video.asm", "vid_depth_debit", "jr nc, .ok",
     ("ld a, (vidDepthClip)", "inc a", "ld (vidDepthClip), a"),
     "never taken: a depth clamp is a bookkeeping bug"),
    ("src/interrupts.asm", "im2_isr", "nextreg NR_MMU7, AUD_PAGE_HI",
     ("call aud_dbg_snap",),
     "audEnable != 0 path, never taken in a session"),
]

# The timed-path instruments wrapped in IFNDEF NXB_QUIET, skipped by --debug
# only: (file, routine, statement before the enclosing IFDEF DEBUG, exact
# statement list, instrument). No match fails the check.
QUIET_PINNED = [
    ("src/video.asm", "vid_dst_norm_gap", "vid_dst_norm_gap:",
     ("ld a, (vidRlDiv)", "dec a", "ld (vidRlDiv), a", "call z, vid_rl_poll"),
     "PLAY= raster arm, per chunk (gapped)"),
    ("src/video.asm", "vid_dst_norm_flat", "vid_dst_norm_flat:",
     ("ld a, (vidRlDiv)", "dec a", "ld (vidRlDiv), a", "call z, vid_rl_poll"),
     "PLAY= raster arm, per chunk (flat)"),
    ("src/video.asm", "vid_pace_poll", "vid_pace_poll:",
     ("ld a, (vidRlSpinDiv)", "dec a", "ld (vidRlSpinDiv), a",
      "call z, vid_rl_poll"),
     "PLAY= spin arm, wait loops"),
    ("src/video.asm", "vid_aud_pump", ".next:",
     ("ld a, (vidRlSpinDiv)", "dec a", "ld (vidRlSpinDiv), a",
      "call z, vid_rl_poll"),
     "PLAY= spin arm, per feed chunk"),
    ("src/video.asm", "vid_run", ".frameloop:",
     ("call vid_play_frame",),
     "FRM=/PLAY=/NOM= per-frame hook"),
    ("src/video.asm", "vid_ring_gate", "vid_ring_gate:",
     ("ld hl, (vidRingDepth)", "ld de, (vidRingMin)", "or a", "sbc hl, de",
      "jr nc, .nomin", "ld hl, (vidRingDepth)", "ld (vidRingMin), hl",
      ".nomin:"),
     "RING= minimum depth"),
    ("src/video.asm", "vid_ring_gate", "ret nc",
     ("ld hl, (vidRingUnder)", "inc hl", "ld (vidRingUnder), hl"),
     "RING= underrun count"),
    ("src/video.asm", "vid_sd_tok_h", ".got:",
     ("push af", "push de", "push hl", "ld hl, 0", "or a", "sbc hl, bc",
      "ex de, hl", "ld hl, (vidTokPolls)", "add hl, de",
      "ld (vidTokPolls), hl", "ld hl, (vidTokCalls)", "inc hl",
      "ld (vidTokCalls), hl", "pop hl", "pop de", "pop af"),
     "TOK= accumulator"),
    ("src/video.asm", "vid_ds_blkopen", "vid_ds_blkopen:",
     ("ld a, (vidRlDiv)", "dec a", "ld (vidRlDiv), a", "call z, vid_rl_poll"),
     "PLAY= raster arm, per direct-serve block"),
]

# The other COLD top-level IFDEF DEBUG blocks, for --list only - never
# skipped. (file, owning label, anchor statements, reason); the anchor is
# the whole statement list, else a contiguous run inside it.
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
    ("src/video.asm", "vidSvHook", ("MMU 6, NXB_PAGE, DATA_WINDOW",),
     "NXB_PAGE: bench tables"),
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
]

LST_ROW = re.compile(r"^\s*(\d+)\+*\s*([0-9A-F]{4})(?: (.*))?$")
LABEL = re.compile(r"^([A-Za-z_]\w*):")
COND_OPEN = {"IF", "IFN", "IFDEF", "IFNDEF", "IFUSED", "IFNUSED"}
UNCOND = re.compile(r"^(?:(?:jp|jr)\s+[^,]+|ret|reti|retn)$", re.IGNORECASE)
NUMBER = re.compile(r"\$[0-9A-Fa-f]+|%[01]+|\b\d[0-9A-Fa-fxX]*[hH]?\b")


class Fail(Exception):
    pass


def rel(path):
    """Listing path -> path relative to SRC_ROOT, posix. sjasmplus runs with
    cwd=ROOT, so a relative listing path resolves against ROOT."""
    p, r = os.path.abspath(os.path.join(ROOT, path)), str(SRC_ROOT) + os.sep
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


def prev_statement(stmts, n):
    """The nearest non-empty statement above line n."""
    k = n - 1
    while k > 0 and not stmts[k - 1]:
        k -= 1
    return stmts[k - 1] if k > 0 else ""


# ------------------------------------------------------------- source side

def scan_source(relpath):
    """Statements, global labels, the owning label of every line, and the
    top-level IFDEF DEBUG blocks."""
    lines = (SRC_ROOT / relpath).read_text(encoding="utf-8").split("\n")
    stmts = [statement(line) for line in lines]
    labels, blocks, owner = [], [], [None] * (len(lines) + 1)
    depth, uncond, conds, cur = 0, None, [], None
    opens, quiet = [], []
    for n, (line, st) in enumerate(zip(lines, stmts), 1):
        word = st.split(" ")[0].upper() if st else ""
        m = LABEL.match(line)
        if m:
            labels.append((m.group(1), n, depth > 0))
            if depth == 0:
                uncond, conds = m.group(1), []
            else:
                conds.append((m.group(1), depth))
        closes = False
        if word in COND_OPEN:
            if depth == 0 and st.upper() == "IFDEF DEBUG":
                cur = {"start": n, "stmts": []}
            opens.append((n, st.upper()))
            depth += 1
        elif word in ("ELSE", "ELSEIF"):
            conds = [c for c in conds if c[1] < depth]
        elif word == "ENDIF":
            depth -= 1
            if depth < 0:
                raise Fail(f"{relpath}:{n}: unbalanced ENDIF")
            start, kind = opens.pop()
            if kind == "IFNDEF NXB_QUIET":
                quiet.append({"start": start, "end": n,
                              "parent": opens[-1] if opens else (0, ""),
                              "stmts": [x for x in stmts[start:n - 1] if x]})
            conds = [c for c in conds if c[1] <= depth]
            closes = depth == 0 and cur is not None
        owner[n] = conds[-1][0] if conds else uncond
        if closes:
            cur["end"] = n
            blocks.append(cur)
            cur = None
        elif cur is not None and st and n != cur["start"]:
            cur["stmts"].append(st)
    for b in blocks:
        b["owner"] = owner[b["start"]]
        b["prev"] = prev_statement(stmts, b["start"])
    for b in quiet:
        b["owner"] = owner[b["start"]]
        b["prev"] = prev_statement(stmts, b["parent"][0])
    return {"lines": lines, "stmts": stmts, "labels": labels,
            "owner": owner, "blocks": blocks, "quiet": quiet}


def label_line(relpath, scan, name):
    hits = [n for lab, n, _ in scan["labels"] if lab == name]
    if len(hits) != 1:
        raise Fail(f"{relpath}: label {name} found {len(hits)} times")
    return hits[0]


class TimedSet:
    """Which source lines are timed, plus the source-side verdicts."""

    def __init__(self, debug=False):
        self.scans, self.problems, self.notes = {}, [], []
        self.skip, self.align_ok, self.spans = {}, set(), {}
        self.quiet_skip = {}
        files = set(TIMED) | set(REGIONS) | {f for f, *_ in TIMED_SPANS}
        files |= {f for f, *_ in COLD_PINNED} | {f for f, *_ in COLD}
        files |= {f for f, *_ in QUIET_PINNED}
        for f in sorted(files):
            self.scans[f] = scan_source(f)
        for f, names in TIMED.items():
            for name in names:
                label_line(f, self.scans[f], name)
        for f, name, start, stop in TIMED_SPANS:
            scan = self.scans[f]
            label_line(f, scan, name)
            own = [n for n in range(1, len(scan["lines"]) + 1)
                   if scan["owner"][n] == name]
            s = next((n for n in own if re.match(re.escape(start) + r"\b",
                                                 scan["lines"][n - 1])), None)
            e = next((n for n in own if s and n >= s
                      and scan["stmts"][n - 1] == stop), None)
            if s is None or e is None:
                raise Fail(f"{f}: span {name}{start} .. '{stop}' not found")
            self.spans.setdefault(f, []).append((name, s, e))
        self._regions()
        self._pinned()
        if debug:
            self._quiet_pinned()
        self._aligns()

    def timed(self, f, n):
        scan = self.scans.get(f)
        if scan is None or n >= len(scan["owner"]):
            return False
        own = scan["owner"][n]
        if own in TIMED.get(f, ()):
            return True
        return any(own == name and s <= n <= e
                   for name, s, e in self.spans.get(f, ()))

    def skipped(self, f, n):
        return any(a <= n <= b for a, b in
                   self.skip.get(f, []) + self.quiet_skip.get(f, []))

    def _regions(self):
        for f, (first, after) in REGIONS.items():
            scan = self.scans[f]
            a = label_line(f, scan, first)
            b = (label_line(f, scan, after) - 1 if after
                 else len(scan["lines"]))
            known = (set(TIMED.get(f, ())) | set(EXCLUDED.get(f, ()))
                     | {r for g, r, *_ in TIMED_SPANS if g == f})
            for name, n, _ in scan["labels"]:
                if a <= n <= b and name not in known:
                    self.problems.append(
                        f"{f}:{n}: global label {name} in the timed region is "
                        f"not classified - add it to TIMED or EXCLUDED")

    def _pinned(self):
        for f, routine, prev, exact, _ in COLD_PINNED:
            hits = [b for b in self.scans[f]["blocks"]
                    if b["owner"] == routine and b["prev"] == prev
                    and tuple(b["stmts"]) == exact]
            if len(hits) != 1:
                self.problems.append(
                    f"{f}: pinned COLD block in {routine} (after '{prev}': "
                    f"{' / '.join(exact)}) matches {len(hits)} blocks - "
                    f"reclassify it or update COLD_PINNED")
                continue
            self.skip.setdefault(f, []).append((hits[0]["start"],
                                                hits[0]["end"]))

    def _quiet_pinned(self):
        for f, routine, prev, exact, _ in QUIET_PINNED:
            hits = [b for b in self.scans[f]["quiet"]
                    if b["owner"] == routine and b["prev"] == prev
                    and b["parent"][1] == "IFDEF DEBUG"
                    and tuple(b["stmts"]) == exact]
            if len(hits) != 1:
                self.problems.append(
                    f"{f}: pinned NXB_QUIET block in {routine} (before its "
                    f"IFDEF DEBUG: '{prev}': {' / '.join(exact)}) matches "
                    f"{len(hits)} blocks - reclassify it or update QUIET_PINNED")
                continue
            self.quiet_skip.setdefault(f, []).append((hits[0]["start"],
                                                      hits[0]["end"]))

    def _aligns(self):
        for f, scan in self.scans.items():
            for n, st in enumerate(scan["stmts"], 1):
                if (st.split(" ")[0].upper() == "ALIGN" and self.timed(f, n)
                        and UNCOND.match(prev_statement(scan["stmts"], n))):
                    self.align_ok.add((f, n))

    def cold_listing(self):
        """(file, start, end, label, reason, pinned) for --list."""
        out = []
        for f, routine, prev, exact, reason in QUIET_PINNED:
            for b in self.scans[f]["quiet"]:
                if ((b["start"], b["end"]) in self.quiet_skip.get(f, ())
                        and b["owner"] == routine and b["prev"] == prev
                        and tuple(b["stmts"]) == exact):
                    out.append((f, b["start"], b["end"], routine,
                                "NXB_QUIET: " + reason, True))
        for f, routine, prev, exact, reason in COLD_PINNED:
            for b in self.scans[f]["blocks"]:
                if (b["owner"], b["prev"], tuple(b["stmts"])) == \
                        (routine, prev, exact):
                    out.append((f, b["start"], b["end"], routine, reason, True))
        for f, owner, anchor, reason in COLD:
            blocks = [b for b in self.scans[f]["blocks"] if b["owner"] == owner]
            hits = [b for b in blocks if tuple(b["stmts"]) == anchor]
            if not hits:
                k = len(anchor)
                hits = [b for b in blocks
                        if any(tuple(b["stmts"][i:i + k]) == anchor
                               for i in range(len(b["stmts"]) - k + 1))]
            if len(hits) != 1:
                self.notes.append(f"note: COLD entry {f} {owner} {anchor[0]!r} "
                                  f"matches {len(hits)} blocks")
                continue
            out.append((f, hits[0]["start"], hits[0]["end"], owner, reason,
                        False))
        return out

    def intervals(self):
        """(file, start, end, name) runs of timed lines for --list."""
        out = []
        for f, scan in self.scans.items():
            run = None
            for n in range(1, len(scan["lines"]) + 1):
                name = scan["owner"][n] if self.timed(f, n) else None
                if run and run[3] == name:
                    run[2] = n
                    continue
                if run and run[3]:
                    out.append(tuple(run))
                run = [f, n, n, name]
            if run and run[3]:
                out.append(tuple(run))
        return out


# ------------------------------------------------------------ listing side

def build(flavour):
    d = OUT / flavour
    (d / "build").mkdir(parents=True, exist_ok=True)
    lst = d / "nextdaad.lst"
    if lst.exists():
        lst.unlink()

    def arg(p):
        return os.path.relpath(p, ROOT).replace(os.sep, "/")
    cmd = [str(SJASM), "--zxnext=cspect", "--msg=war", "--fullpath",
           f"--outprefix={arg(d)}/", f"--lst={arg(lst)}",
           *FLAVOURS[flavour], arg(SRC_ROOT / "src" / "main.asm")]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0 or not lst.exists():
        tail = (r.stdout + r.stderr).strip().splitlines()[-15:]
        raise Fail(f"{flavour} assembly failed:\n  " + "\n  ".join(tail))
    return lst, d / "build" / "nextdaad.nex"


def parse_listing(lst):
    """Rows (file, line, count, src, key text, is ALIGN)."""
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
        raw.append((files[-1], int(m.group(1)), int(m.group(2), 16),
                    rest[:12], rest[12:13], rest[13:]))
    rows = []
    for i, (f, n, addr, field, flag, src) in enumerate(raw):
        if field.startswith("~"):
            continue
        if "..." in field:
            nxt = raw[i + 1][2] if i + 1 < len(raw) else addr
            count = (nxt - addr) & 0xFFFF
        else:
            count = len(re.findall(r"\b[0-9A-F]{2}\b", field))
        st = statement(src)
        align = st.split(" ")[0].upper() == "ALIGN"
        if not count and not align:
            continue
        # a data line over 4 bytes continues on rows with no source text
        if not src.strip() and flag != ">" and rows and rows[-1][:2] == (f, n) \
                and not rows[-1][5]:
            prev = rows[-1]
            rows[-1] = (f, n, prev[2] + count) + prev[3:]
            continue
        # expanded macro/DUP rows share line numbers: key on masked text too
        key = NUMBER.sub("#", st) if flag == ">" else ""
        rows.append((f, n, count, src, key, align))
    return rows


def select(rows, ts):
    out = []
    for f, n, count, src, key, align in rows:
        if not ts.timed(f, n) or ts.skipped(f, n):
            continue
        if align and (f, n) in ts.align_ok:
            count = None                 # padding after a jump never runs
        out.append((f, n, count, src, key))
    return out


# ------------------------------------------------------------------ compare

def compare(a_name, a, b_name, b):
    """Print each differing line with both byte counts; return the count."""
    def show(c):
        return "ALIGN" if c is None else f"{c} B"
    ka = [(r[0], r[1], r[4]) for r in a]
    kb = [(r[0], r[1], r[4]) for r in b]
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
            for f, n, c, src, key in part:
                e = agg.setdefault((f, n, key), [0, 0, src])
                e[side] = None if c is None else (e[side] or 0) + c
        region = [(f, n, show(ca), show(cb), src)
                  for (f, n, _), (ca, cb, src) in agg.items() if ca != cb]
        if not region:
            f, n, _ = (ka[i1:i2] or kb[j1:j2])[0]
            region = [(f, n, "-", "-", "line order differs")]
        diffs += region
    for f, n, ca, cb, src in diffs:
        print(f"DIFF {f}:{n}: {a_name} {ca}, {b_name} {cb} | {src.strip()}")
    return len(diffs)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def run(args, built):
    other = "debug" if args.debug else "quiet"
    ts = TimedSet(debug=args.debug)
    cold = ts.cold_listing()
    if args.list:
        for f, a, b, name in ts.intervals():
            print(f"TIMED {f}:{a}-{b} {name}")
        for f, a, b, owner, reason, pinned in cold:
            tag = " (pinned, skipped)" if pinned else ""
            print(f"COLD  {f}:{a}-{b} {owner}: {reason}{tag}")
    sel = {}
    for flavour in ("release", other):
        lst, nex = build(flavour)
        built.add(sha(nex))
        sel[flavour] = select(parse_listing(lst), ts)
        print(f"{flavour:8} {os.path.relpath(nex, ROOT)} sha256 {sha(nex)}")
    for note in ts.notes:
        print(note)
    for problem in ts.problems:
        print(f"FAIL {problem}")
    rows_r = sel["release"]
    names = [(f, name) for f, names in TIMED.items() for name in names]
    names += [(f, name) for f, name, *_ in TIMED_SPANS]
    empty = [(f, name) for f, name in names
             if not any(r[0] == f and ts.scans[f]["owner"][r[1]] == name
                        for r in rows_r)]
    for f, name in empty:
        print(f"FAIL {f}: timed routine {name} assembles no bytes in release")
    ndiff = compare("release", rows_r, other, sel[other])
    nbytes = sum(r[2] or 0 for r in rows_r)
    nquiet = sum(len(v) for v in ts.quiet_skip.values())
    print(f"timed set: {len(names)} routines, {len(rows_r)} assembled lines, "
          f"{nbytes} B; {sum(len(v) for v in ts.skip.values())} pinned COLD "
          f"blocks skipped" + (f", {nquiet} pinned NXB_QUIET blocks skipped"
                               if args.debug else ""))
    if ndiff or empty or ts.problems:
        print(f"FAIL: {ndiff} line(s) differ, {len(ts.problems) + len(empty)} "
              f"classification failure(s)")
        return 1
    if args.debug:
        print("OK: debug timed paths are instruction-identical to release "
              "outside the NXB_QUIET instruments")
    else:
        print("OK: quiet timed paths are instruction-identical to release")
    return 0


def main():
    global SRC_ROOT, OUT
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0], epilog=HELP,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true",
                    help="print the timed line runs and the COLD blocks")
    ap.add_argument("--debug", action="store_true",
                    help="compare Release with standard DEBUG instead of quiet")
    ap.add_argument("--src-root", help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.src_root:
        SRC_ROOT = Path(args.src_root).resolve()
        OUT = SRC_ROOT / "out"
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
