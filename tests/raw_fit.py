#!/usr/bin/env python3
"""tests/raw_fit.py - raw direct gate constants from an RW1 bench log (verb NXBW).

Fits T = Spix (512 tb F + ts) + Ssnd tsnd + C tc + tf + P tp + stall per sound form,
after taking the tracked bench harness out of every row (nxv2_bench_rows
RW_CARD_HARNESS_T, RW_FRAME_HARNESS_T; --model 1b: RW_FRAME_HARNESS_T_1B, the frame
harness of the images sitting 1b's committed logs came from).

Usage: python tests/raw_fit.py NXBENCH.TXT [--clips DIR] [--nr11 N] [--playback FILE]
                                            [--wait-shape inline|sitting1] [--model 1c|1b]
       python tests/raw_fit.py --selftest
The token wait shape is read from the log: a capture with an RH39 or AH39 row or histogram
is the inline wait (22 T, then 47 T a poll), a log with neither is sitting 1's (48 T a poll,
vid_sd_tok_h); --wait-shape overrides it.
Exit 0 when every residual is within ACCEPT_PCT, the sound-term rule holds (SOUND_D_MAX,
SOUND_ERR_PCT) and no row is listed for a RE-RUN, 1 when not, 2 on a log or fit error.
"""
import argparse
import re
import sys
import tempfile
from dataclasses import dataclass, field, replace
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
for _p in (REPO / "authoring-kit" / "lib", REPO / "tests" / "core303", REPO / "tests"):
    sys.path.insert(0, str(_p))

import nxv2_bench_log as benchlog      # noqa: E402
import nxv2_bench_rows as benchrows    # noqa: E402
import nxv2enc                         # noqa: E402
import parse as nxbparse               # noqa: E402
import tags as nxbtags                 # noqa: E402

H_CARD = benchrows.RW_CARD_HARNESS_T
# The frame harness of the bench image a log came from: 1c this tree's, 1b sitting 1b's.
MODEL_G_FRAME = {"1c": benchrows.RW_FRAME_HARNESS_T, "1b": benchrows.RW_FRAME_HARNESS_T_1B}
G_FRAME = MODEL_G_FRAME["1c"]
INI_T = 16
SECTOR_INI_T = 512 * INI_T
COL_ENDS = 8                 # RCOL/ARCO: 8 reads of 64 (nxb_rw_col)
COL_END_DESIGN_T = 38        # schedule column end: ret, ld l,0, inc h, call
ACCEPT_PCT = 1.0
PEER_PCT = 3.0
NEAR_UTIL = 0.90             # the encoder's existing warning threshold
# The bench board's machine timing (+3, 50 Hz): NR $03 bits 6-4 = 3, NR $05 bit 2 = 0.
BENCH_NR = {"03": 3 << 4, "05": 0}
LPF, TPL35 = nxbparse.timing(BENCH_NR)
T_LINE = TPL35 * 8
PERIOD_NUM = 2 * LPF * T_LINE * 25     # T per frame x fps: two fields at 25 fps
assert PERIOD_NUM == 28_363_200
# Token wait shape: T of the first $FF poll and of each later one. sitting1: vid_sd_tok_h's
# 48 T loop (sitting 1's bench); inline: vr_sector_n's wait and its nxb_rh_sec mirror.
WAIT_SHAPES = {"sitting1": (48, 48),
               "inline": (nxbtags.NXB_HIST_POLL1_T, nxbtags.NXB_HIST_POLL_T)}
# Rows only the inline-wait bench prints (the 39 T first-poll comparison); sitting 1 has none.
INLINE_TAGS = ("RH39", "AH39")
# 256 or more polls, a RE-RUN: 256 is the djnz loop's last poll; the mirror counts every
# longer wait (vid_sd_tok_h, 257 and up) as 256.
HIST_BIN_LONG = 9
GLUE_T = nxv2enc.TMODEL_COEFFS["glue_t"] / nxv2enc.TMODEL_COEFFS["audio_factor"]

# tests/build-tests.ps1 -VidRawBench clips: clip -> (width, height, fps, channels, frames)
FIXTURES = {
    60: (256, 192, 25, 2, 250), 61: (320, 160, 25, 2, 250), 62: (320, 192, 25, 2, 250),
    63: (280, 224, 25, 2, 250), 64: (320, 240, 16.67, 2, 167), 65: (256, 240, 16.67, 2, 167),
    66: (256, 192, 25, 1, 250), 67: (320, 160, 25, 1, 250), 68: (320, 192, 25, 1, 250),
    69: (280, 224, 25, 1, 250), 70: (320, 240, 16.67, 1, 167), 71: (256, 240, 16.67, 1, 167),
    72: (320, 256, 12.5, 2, 125), 74: (256, 192, 15.2587890625, 1, 153),
    # sound-term clips: mono 1250 B in 3 sectors, stereo 1562 B in 4 (pad 286, 486)
    88: (256, 192, 12.5, 1, 250), 89: (256, 192, 20, 2, 200),
}
# Leg B playback clips outside the fit (shape known, same table).
PLAYBACK_ONLY = {73: (256, 192, 25, 2), 75: (256, 192, 25, 2), 76: (256, 192, 25, 1),
                 77: (256, 192, 25, 2), 78: (256, 192, 25, 1), 79: (320, 256, 25, 2)}
FORMS = ("stereo", "mono")
TARGETS = ((256, 192, 25), (320, 160, 25), (320, 192, 25), (280, 224, 25),
           (320, 240, 16.67), (256, 240, 16.67))
RW1_TAGS = benchlog.table_tags("NXBW")
DS1_TAGS = benchlog.table_tags("NXBD")
RW1_REPS = {r[0]: r[3] for r in benchrows.SESSION_TABLES["RW1"] if r[0] in RW1_TAGS}
OTHER_LAYOUT_PCT = 0.5       # allowance for sound layouts outside the fitted pairs
# One term a sound sector holds while the pad-aware d is small and the gate stays near that fit.
SOUND_D_MAX = 3.0            # |d|, T a sound byte, each form
SOUND_ERR_PCT = 0.15         # |gate - fit|, percent of the period, every listed layout
SOUND_FPS = (30, 25, 20, 16.67, 15.2587890625, 12.5, 10.5)


def sound_note(res, form):
    """The note printed with a form's sound constants: what fixes them, where they hold."""
    groups = {}
    for c, s, _ in res.lsq[form]:
        groups.setdefault(s, []).append(c)
    desc = ", ".join("Ssnd %d: %s" % (s, " ".join("%03d" % c for c in v))
                     for s, v in sorted(groups.items()))
    lone = [(s, v[0]) for s, v in sorted(groups.items()) if len(v) == 1]
    if len(groups) == 2:
        how = "are fixed exactly by the two groups' means (%s)" % desc
        if lone:
            how += "; %03d's residual is 0 by construction" % lone[0][1]
    else:
        how = "rest on %d groups for two constants, %d degree(s) of freedom (%s)" % (
            len(groups), len(groups) - 2, desc)
    fps = sorted({res.clips[c].shape[2] for c, _, _ in res.lsq[form]}, reverse=True)
    return ("note: %s sound constants %s; valid for the fitted pairs only (%s at %s fps); "
            "elsewhere allow about %.1f percent" % (form, how, form,
                                                    ", ".join("%g" % f for f in fps),
                                                    OTHER_LAYOUT_PCT))


class FitError(Exception):
    pass


def form_of(channels):
    return "stereo" if channels == 2 else "mono"


def inc_equ(name):
    """An equ value from src/nextdaad.inc (decimal or $hex)."""
    for line in (REPO / "src" / "nextdaad.inc").read_text(encoding="latin-1").splitlines():
        p = line.split()
        if p[:2] == [name, "equ"]:
            return int(p[2][1:], 16) if p[2].startswith("$") else int(p[2])
    raise FitError("%s is not in src/nextdaad.inc" % name)


def ctc_period():
    """(prescaler, time constants by NR $11 & 7) as the player sets CTC 0: AUD_CTC_CW16
    bit 5 picks /16 or /256; vidCtcTcNxvStereo holds the time constants."""
    pre = 256 if inc_equ("AUD_CTC_CW16") & 0x20 else 16
    asm = (REPO / "src" / "video.asm").read_text(encoding="latin-1").splitlines()
    at = next(i for i, l in enumerate(asm) if l.startswith("vidCtcTcNxvStereo:"))
    tcs = [int(x) for x in asm[at + 1].split(None, 1)[1].split(",")]
    return pre, tcs


FIELD_T = LPF * T_LINE
# Plain DEBUG (IFNDEF NXB_QUIET) base T absent from the -BenchQuiet rows, Zilog T counted
# from src/video.asm (NEXTREG A,n read 13 T); vid_rl_poll runs once per VID_RL_DIV arms.
DBG = dict(
    arm=40,          # divider arm: ld a,(nn) / dec a / ld (nn),a / call z, not taken
    rl_poll=231,     # vid_rl_poll body, plus 7 T for the call z taken
    sector=86,       # vr_sector_n: ld d,0 / call vid_dst_norm_flat / its arm / ld a,d, cp, ret c
    token=177,       # vid_sd_tok_h .got poll counter: every sound sector; a pixel sector only
                     # in the sitting1 shape (inline: the slow tail, 257 or more polls)
    play_frame=179,  # call vid_play_frame, the armed path
    late=174,        # call vid_dbg_late, a late frame, MAXL not raised
    urun=402,        # call vid_dbg_urun and its vid_pace_poll (raw .rd), a late frame
)


def pix_token(res):
    """DEBUG token counter T a pixel sector: vid_sd_tok_h ran every pixel open in sitting 1's
    shape; the inline open (vr_sector_n) calls it only past its djnz loop."""
    return DBG["token"] if res.wait_shape == "sitting1" else 0


def infer_wait_shape(sections):
    """inline when any capture carries an INLINE_TAGS row or histogram, else sitting1."""
    for s in sections:
        if any(t in s.rows or t in s.hist for t in INLINE_TAGS):
            return "inline"
    return "sitting1"


def shape_tags(res, tags):
    """The tags a log of res's wait shape carries: sitting 1's bench had no INLINE_TAGS."""
    return [t for t in tags if res.wait_shape == "inline" or t not in INLINE_TAGS]


# Card-row refusals printed as "TAG <marker>" in place of the row, by cause.
REFUSALS = nxbtags.NXB_RW1_REFUSALS


def debug_work(res, g, form):
    """Plain DEBUG T on a late frame's path, armed (1 / (1 - handler / CTC period)).
    Pump passes a frame are estimated: one chunk, one more on a ring-tail wrap, the last.
    A pixel sector carries the token counter only in the sitting1 shape (pix_token)."""
    am = res.period / (res.period - res.handler[form])
    rl = DBG["rl_poll"] / inc_equ("VID_RL_DIV")
    pix = DBG["sector"] + pix_token(res) + rl
    snd = DBG["arm"] + DBG["token"] + rl
    passes = 2 + g.real / inc_equ("NXV_AUD_RING")
    frame = (DBG["play_frame"] + DBG["arm"] + rl + DBG["late"] + DBG["urun"] + rl
             + passes * (DBG["arm"] + rl))
    return SimpleNamespace(pix=pix, snd=snd, frame=frame, passes=passes, armed=am,
                           total=am * (g.spix * pix + g.ssnd * snd + frame), pal=am * pix)


def ring_play(frames, work, work0, real, channels, tick, ring, guard, chunk):
    """vid_run's frame loop against the CTC 0 reader: release on consumption with the deficit
    clamp (.pace/.paced), .ffin waits for ring room, .qnext pumps what vid_aud_pump's room
    test and chunk floor allow. -> (T from frame 0's loop top to the drain release, waits)."""
    def rd(t):
        return channels * int(t // tick)

    def until(target):
        return tick * -(-target // channels)

    t, wr, seen, rem, feed, laps = 0.0, real, 0, 0, 0, 0
    for f in range(frames):
        now = rd(t)
        rem -= now - seen
        seen = now
        if rem > 0:
            t = max(t, until(seen + rem))
            now = rd(t)
            rem -= now - seen
            seen = now
        rem += real
        if rem <= 0:
            rem = real
        if feed:
            short = (wr - rd(t)) % ring - (ring - guard - feed)
            if short > 0:
                t = max(t, until(rd(t) + short))
                laps += 1
            wr += feed
            feed = 0
        t += work0 if f == 0 else work
        if f == frames - 1:
            break
        room = ring - guard - (wr - rd(t)) % ring
        if room >= real:
            wr += real
        elif room >= chunk or 0 < room and real < chunk:
            wr += room
            feed = real - room
        else:
            feed = real
    now = rd(t)
    rem -= now - seen
    if rem > 0:
        t = max(t, until(now + rem))
    return t, laps


def geometry(width, height, fps, channels):
    sw, _ = nxv2enc.raw_surface(width, height)
    lay = nxv2enc.raw_layout(width, height, sw)
    _rate, samples, real, padded = nxv2enc.audio_layout(fps, channels, raw=True)
    return SimpleNamespace(spix=lay["sectors"], ssnd=padded // 512, cols=lay["columns"],
                           surface=sw, samples=samples, real=real, padded=padded)


def row_t(row):
    """Total T of an NXB row (O, R, F, D) on the bench long clock."""
    return nxbparse._nxb_t(SimpleNamespace(f=row[2], d=row[3]), LPF, TPL35)


# ---------------------------------------------------------------------------
# Synthetic log for the selftest: rows generated from known constants through
# raw_model_t plus the harness, quantised to raster lines like the bench clock.
# ---------------------------------------------------------------------------

SYNTH = dict(
    ts=361.5, tc_unarmed=38.0, spn0=52131.7, old_handler=175.2,
    k={"stereo": dict(tb=17.31, tsnd=9123.0, tc=40.62, tf=21456.0, tp=10234.0),
       "mono": dict(tb=17.02, tsnd=8711.0, tc=39.87, tf=4321.0, tp=9987.0)},
    duty={"stereo": 1.0712, "mono": 1.0583},
    handler={"stereo": 124.3, "mono": 101.9},
    stall_bin={63: 3},
)
# Large reps keep the line quantisation far below 0.1 percent of every constant.
SYNTH_REPS = dict(RFR0=4096, RSWP=4096, ARSW=4096, RSEC=65535, RCOL=65535, RHST=2048,
                  RH39=2048, SPN0=8192, ARSE=65535, ARCO=65535, AHST=2048, AH39=2048,
                  ASPN=8192, OSPN=8192)


def synth_t(clip, P=SYNTH):
    """Per-rep T of each RW1 row of a clip, harness included, from P."""
    w, h, fps, ch, _n = FIXTURES[clip]
    form = form_of(ch)
    g = geometry(w, h, fps, ch)
    k = dict(P["k"][form], ts=P["ts"])
    rsec = SECTOR_INI_T + P["ts"] + H_CARD
    rcol = rsec + COL_ENDS * P["tc_unarmed"]
    arse_p = P["ts"] + 512 * k["tb"]
    arco_p = arse_p + COL_ENDS * k["tc"]
    arsw_p = nxv2enc.raw_model_t(g.spix, g.ssnd, g.cols, False, k)["total_t"]
    pad_t = P.get("pad_t", 0.0)                            # a pad byte surcharge, armed:
    if isinstance(pad_t, dict):                            # T, or {form: T}
        pad_t = pad_t.get(form, 0.0)
    arsw_p += pad_t * (g.padded - g.real)
    rswp_p = arsw_p / P["duty"][form]
    pre, tcs = ctc_period()
    per = pre * tcs[0]
    s0 = P["spn0"]
    return dict(
        RFR0=rswp_p + k["tp"] * rswp_p / arsw_p + G_FRAME,
        RSWP=rswp_p + G_FRAME,
        ARSW=arsw_p * (rswp_p + G_FRAME) / rswp_p,
        RSEC=rsec, RCOL=rcol, RHST=rsec + 150.0, RH39=rsec + 171.0, SPN0=s0,
        ARSE=arse_p * rsec / (rsec - H_CARD),
        ARCO=arco_p * rcol / (rcol - H_CARD),
        AHST=arse_p * rsec / (rsec - H_CARD) + 160.0,
        AH39=arse_p * rsec / (rsec - H_CARD) + 182.0,
        ASPN=s0 / (1 - P["handler"][form] / per),
        OSPN=s0 / (1 - P["old_handler"] / per))


def _fd(total_t, flip):
    lines = round(total_t / T_LINE)
    f = lines // LPF
    d = lines - f * LPF
    if flip and d >= 0:
        f, d = f + 1, d - LPF
    assert 0 <= f < 0x10000 and -0x8000 <= d < 0x8000
    return f, d


def _row_line(tag, o, r, f, d):
    return "%s O=%02X R=%04X F=%04X D=%04X" % (tag, o, r, f, d & 0xFFFF)


def synth_log(P=SYNTH, marks=(), stale_after=None, distort=None, short=None, swap=None,
              omit=()):
    """NXBENCH.TXT text: one NXBW capture per fixture clip not in omit, then an NXBD capture
    on clip 10. marks: (clip, tag) rows printed with O = 01 and T x 1.05; stale_after:
    a clip followed by a PICK 59 capture that prints VID FILE? over the old rows;
    distort: (clip, tag, factor) applied to an unmarked row; short: (clip, tag) printed
    as the NXB SHORT marker in place of the row, or (clip, tag, marker) with that refusal;
    swap: a clip whose ASPN carries the other form's handler."""
    out, stamp = [], 0x0600

    def cap(lines):
        nonlocal stamp
        out.append("#NXB %04X" % stamp)
        stamp += 0x0321
        out.extend(lines)

    for n, clip in enumerate(c for c in sorted(FIXTURES) if c not in omit):
        w, h, fps, ch, frames = FIXTURES[clip]
        t = synth_t(clip, P)
        if clip == swap:
            pre, tcs = ctc_period()
            t["ASPN"] = P["spn0"] / (1 - P["handler"][form_of(3 - ch)] / (pre * tcs[0]))
        body = ["What now?", ">pick %d" % clip,
                "Clip %d armed - GO plays once, LOOP loops." % clip, "What next?", ">nxbw",
                _row_line("IDEN", 2, frames, w, h & 0xFF)]
        for i, tag in enumerate(RW1_TAGS[1:]):
            reps = SYNTH_REPS[tag]
            o, tt = 0, t[tag]
            if (clip, tag) in marks:
                o, tt = nxbtags.NXB_RW1_WALK_O, tt * 1.05
            if distort and distort[:2] == (clip, tag):
                tt *= distort[2]
            if short and tuple(short[:2]) == (clip, tag):
                body.append(tag + " " + (short[2] if len(short) > 2 else "NXB SHORT"))
                continue
            body.append(_row_line(tag, o, reps, *_fd(tt * reps, (clip + i) % 2)))
        rows = body[5:]
        tail = [" FRM=0000/0000 ERR=00 OP=00 POS=000000 PASS=01",
                "RING   =0000/0000/00 FILL=0001 SNAP=00", "PLAY   =0000 NOM=0000 CHK=00000000"]
        hist = []
        for tag in nxbtags.NXB_HIST_TAGS:
            bins = [0] * nxbtags.NXB_HIST_BINS
            top = P["stall_bin"].get(clip) if tag == "AHST" else None
            bins[1] = SYNTH_REPS[tag] - (1 if top else 0)
            if top:
                bins[top] = 1
            hist.append("#HIST %s %s" % (tag, " ".join("%04X" % b for b in bins)))
        cap(body + tail + (["LOG OK"] if n else []) + hist)
        if clip == stale_after:
            cap(["What now?", ">pick 59", "Clip 59 armed - GO plays once, LOOP loops.",
                 "What next?", ">nxbw"] + rows + ["VID FILE?"] + tail + ["LOG OK"])
    old = dict(DSWP=(16, 1, 24, -19), ADSW=(16, 1, 27, -145), DTI0=(0, 128, 2, 10),
               DTB0=(0, 128, 4, 127), DTC0=(0, 128, 2, 59), DTD0=(0, 128, 2, 123),
               ADTI=(0, 128, 2, 78), ADTC=(0, 128, 2, 133))
    cap(["What now?", ">pick 10", "Clip 10 armed - GO plays once, LOOP loops.",
         "What next?", ">nxbd", _row_line("IDEN", 2, 250, 256, 167)]
        + [_row_line(tg, *old[tg]) for tg in DS1_TAGS[1:]]
        + [" FRM=0000/0000 ERR=00 OP=00 POS=000000 PASS=01", "LOG OK"])
    return "\r\n".join(out) + "\r\n"


# ---------------------------------------------------------------------------
# The log and the fit
# ---------------------------------------------------------------------------

# An open or session failure: the bench hook never ran, the rows are a previous screen.
FAIL_RE = re.compile(r"^(VID (FILE\?|FMT\?|NOBANK2|SIZE\?|FRAG\?)|NXB SESSION|NXB NO BANK)")
MARKER_RE = re.compile(r"NXB (SHORT|RUN|GEO)\b|\bBAD\b")


@dataclass
class Section:
    index: int               # #NXB capture number, as parse.parse_hist numbers it
    stamp: int
    verb: str
    clip: int                # the last PICK nn at or above the verb
    rows: dict               # tag -> (O, R, F, D)
    hist: dict               # tag -> bins
    failure: str             # the first open-failure line, or None
    err: int
    notes: list = field(default_factory=list)
    markers: list = field(default_factory=list)


def read_sections(path):
    """Captures of an NXB log. Rows and clips come from nxv2_bench_log.parse (every
    capture kept: parse.parse_nxb counts a row equal to the previous capture's once);
    parse.parse_nxb validates the file and parse.parse_hist must agree on #HIST."""
    nxbparse.parse_nxb(path)
    hists = {}
    for sec, tag, bins in nxbparse.parse_hist(path):
        if tag in hists.setdefault(sec, {}):
            raise nxbparse.LogError("section %d: two #HIST %s lines" % (sec, tag))
        hists[sec][tag] = bins
    out = []
    for k, run in enumerate(benchlog.parse(Path(path).read_text(encoding="latin-1")), 1):
        if run.hist != hists.get(k, {}):
            raise nxbparse.LogError("section %d: the two parsers read #HIST differently" % k)
        rows, notes = {}, list(run.warnings)
        for tag, o, r, f, d in run.rows:
            if tag in rows:
                notes.append("row %s printed twice, the last kept" % tag)
            rows[tag] = (o, r, f, d)
        fail = next((l.strip() for l in run.lines if FAIL_RE.match(l.strip())), None)
        marks = [l.strip() for l in run.lines if MARKER_RE.search(l)]
        out.append(Section(k, run.stamp, run.command, run.clip, rows, run.hist, fail,
                           run.err, notes, marks))
    return out


@dataclass
class Clip:
    clip: int
    section: int
    stamp: int
    form: str
    shape: tuple             # (width, height, fps, channels, frames)
    geo: object
    rows: dict               # every printed row
    t: dict                  # usable rows: tag -> T per rep
    p: dict = field(default_factory=dict)    # harness removed (primed), per rep
    hist: dict = field(default_factory=dict)
    notes: list = field(default_factory=list)


@dataclass
class Resid:
    clip: int
    form: str
    spix: int
    ssnd: int
    cols: int
    meas: float
    model: float
    pct: float


@dataclass
class Result:
    log: str = ""
    period: int = 0          # CTC 0 period, T
    ctc: tuple = ()
    clips: dict = field(default_factory=dict)
    excluded: list = field(default_factory=list)
    walked: list = field(default_factory=list)
    anomalies: list = field(default_factory=list)
    checks: list = field(default_factory=list)
    notes: list = field(default_factory=list)
    old: object = None
    ts: float = 0.0
    k: dict = field(default_factory=dict)
    src: dict = field(default_factory=dict)  # form -> {constant: clips used}
    tps: dict = field(default_factory=dict)
    lsq: dict = field(default_factory=dict)
    stall: float = 0.0
    stall_top: tuple = ()
    wait: dict = field(default_factory=dict)
    handler: dict = field(default_factory=dict)
    handler_n: dict = field(default_factory=dict)
    handler_spread: dict = field(default_factory=dict)
    col_unarmed: float = 0.0
    hsum: dict = field(default_factory=dict)
    cmp39: dict = field(default_factory=dict)   # RH39/AH39 key -> (base polls, 39 T polls, clips)
    duty: dict = field(default_factory=dict)
    residuals: list = field(default_factory=list)
    accepted: bool = False
    max_resid: float = 0.0
    clipfiles: object = None
    wait_shape: str = "inline"
    pad: dict = field(default_factory=dict)     # pad_aware
    sound: tuple = ()                           # sound_rule
    sound_ok: bool = False


def _mean(xs):
    xs = list(xs)
    if not xs:
        raise FitError("no rows to average")
    return sum(xs) / len(xs)


def _median(xs):
    xs = sorted(xs)
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def _lsq(points):
    """[(x, y)] -> (intercept, slope) by least squares."""
    n = len(points)
    sx = sum(x for x, _ in points)
    sy = sum(y for _, y in points)
    sxx = sum(x * x for x, _ in points)
    sxy = sum(x * y for x, y in points)
    den = n * sxx - sx * sx
    if n < 2 or den == 0:
        raise FitError("fewer than two Ssnd values: RAW_SND_SECTOR_T is not determined")
    slope = (n * sxy - sx * sy) / den
    return (sy - slope * sx) / n, slope


def _bin_polls(k):
    """(lowest, highest, mean) $FF polls of histogram bin k (bit length of the count)."""
    if k == 0:
        return 0, 0, 0.0
    lo, hi = 2 ** (k - 1), 2 ** k - 1
    return lo, hi, (lo + hi) / 2.0


def _wait_t(shape, polls):
    """T a wait of polls $FF polls (a bin's edge or mean) adds to the token on poll 1."""
    p1, p = WAIT_SHAPES[shape]
    return p1 + p * (polls - 1) if polls >= 1 else 0


def check_clip_file(path, clip):
    """Header fields and frame tags 0-32 of a fixture clip against FIXTURES (read only).
    -> (mismatches, frames carrying a palette sector, bad tags)."""
    w, h, fps, ch, frames = FIXTURES[clip]
    g = geometry(w, h, fps, ch)
    bad, pals, tags = [], [], []
    with open(path, "rb") as f:
        hdr = f.read(512)
        want = dict(magic=(hdr[:5], b"NXVID"), version=(hdr[5], 2),
                    width_code=(hdr[6], 1 if g.surface == 320 else 0),
                    height=(hdr[7], h & 0xFF), channels=(hdr[9], ch),
                    rate=(hdr[10] | hdr[11] << 8, 15625), flags=(hdr[12], 0x13),
                    frames=(hdr[14] | hdr[15] << 8 | hdr[16] << 16, frames),
                    sound_bytes=(hdr[17] | hdr[18] << 8, g.real),
                    cap=(hdr[21] | hdr[22] << 8, g.spix + 1),
                    raw_width=(hdr[23] | hdr[24] << 8, w if g.surface == 320 else 256))
        bad = ["%s %r != %r" % (n, a, b) for n, (a, b) in want.items() if a != b]
        off = 512
        for i in range(33):
            f.seek(off + g.padded - 1)
            b = f.read(1)
            if not b:
                bad.append("file ends before frame %d" % i)
                break
            tags.append(b[0])
            if b[0] == 1:
                pals.append(i)
            off += g.padded + (512 if b[0] == 1 else 0) + g.spix * 512
    return bad, pals, [(i, t) for i, t in enumerate(tags) if t > 1]


def _peer(res, group, values):
    """values {clip: v}: a value more than PEER_PCT from the group median is an anomaly.
    Records (group, n, largest deviation percent) in res.checks."""
    if not values:
        return
    med = _median(values.values())
    worst = 0.0
    for clip, v in sorted(values.items()):
        dev = 0.0 if med == v else (100.0 * (v - med) / med if med else float("inf"))
        worst = max(worst, abs(dev))
        if abs(dev) > PEER_PCT:
            res.anomalies.append("clip %03d %s %.2f is %+.2f%% from its peers' median %.2f "
                                 "(RE-RUN)" % (clip, group, v, dev, med))
    res.checks.append("peers %-22s %2d clips, largest deviation %.2f%%" % (group, len(values),
                                                                        worst))


def fit(sections, reps=RW1_REPS, nr11=0, clips_dir=None, wait_shape=None):
    """wait_shape None: infer_wait_shape(sections)."""
    pre, tcs = ctc_period()
    if wait_shape is None:
        wait_shape = infer_wait_shape(sections)
    res = Result(period=pre * tcs[nr11 & 7], ctc=(pre, tcs[nr11 & 7], nr11),
                 wait_shape=wait_shape)
    marked = set()
    for s in sections:
        if s.verb not in ("NXBW", "NXBD"):
            res.notes.append("section %d: verb %s not used" % (s.index, s.verb))
            continue
        why = s.failure or ("ERR=%02X" % s.err if s.err else None)
        if s.verb == "NXBD":
            if why:
                res.excluded.append(SimpleNamespace(section=s.index, clip=s.clip, stamp=s.stamp,
                                                    verb=s.verb, failure=why))
            else:
                res.old = s
            continue
        shape = FIXTURES.get(s.clip)
        if why is None and shape is None:
            why = "clip %s is not in the fixture table" % s.clip
        if why is None:
            w, h, fps, ch, frames = shape
            want = (2, frames, w, h & 0xFF)
            if s.rows.get("IDEN") != want:
                why = "IDEN %r != fixture (O, frames, width, height byte) %r" % (
                    s.rows.get("IDEN"), want)
        if why:
            res.excluded.append(SimpleNamespace(section=s.index, clip=s.clip, stamp=s.stamp,
                                                verb=s.verb, failure=why))
            continue
        if s.clip in res.clips:
            res.anomalies.append("clip %03d captured twice (sections %d and %d): the later used"
                                 % (s.clip, res.clips[s.clip].section, s.index))
        c = Clip(s.clip, s.index, s.stamp, form_of(shape[3]), shape, geometry(*shape[:4]),
                 s.rows, {}, hist=dict(s.hist))
        runs = [nxbparse.NxbRun(tg, None, *row, s.index, "session") for tg, row in s.rows.items()]
        walked = {r.tag for r in nxbparse.rw1_walked(runs)}
        for tg in shape_tags(res, RW1_TAGS[1:]):
            row = s.rows.get(tg)
            if row is None:
                res.anomalies.append("clip %03d: row %s missing (RE-RUN)" % (s.clip, tg))
            elif tg in walked:
                res.walked.append((s.clip, tg))
                marked.add((s.clip, tg))
            elif row[1] != reps[tg]:
                res.anomalies.append("clip %03d: %s R=%d, the table runs %d (RE-RUN)" % (
                    s.clip, tg, row[1], reps[tg]))
            else:
                c.t[tg] = row_t(row) / row[1]
        for m in s.markers:
            why = next((v for k, v in REFUSALS.items() if re.search(k + r"\b", m)), None)
            res.anomalies.append("clip %03d: marker line %r%s (RE-RUN)" % (
                s.clip, m, ": " + why if why else ""))
        res.clips[s.clip] = c
    if not res.clips:
        raise FitError("no usable NXBW capture")
    clips = [res.clips[k] for k in sorted(res.clips)]

    # Histograms: bins sum to the row's reps; a walk-marked row's histogram is dropped.
    for c in clips:
        for tg in shape_tags(res, nxbtags.NXB_HIST_TAGS):
            bins = c.hist.get(tg)
            if (c.clip, tg) in marked:
                c.hist.pop(tg, None)
            elif bins is None:
                res.anomalies.append("clip %03d: no #HIST %s line (RE-RUN)" % (c.clip, tg))
            elif tg in c.rows and sum(bins) != c.rows[tg][1]:
                res.anomalies.append("clip %03d: #HIST %s bins sum to %d, the row ran %d (RE-RUN)"
                                     % (c.clip, tg, sum(bins), c.rows[tg][1]))
            if bins is not None and (c.clip, tg) not in marked and any(bins[HIST_BIN_LONG:]):
                res.anomalies.append("clip %03d: #HIST %s has %d waits in bin %d or above (256 "
                                     "or more $FF polls) (RE-RUN)" % (
                                         c.clip, tg, sum(bins[HIST_BIN_LONG:]), HIST_BIN_LONG))
    nh = sum(1 for c in clips for tg in nxbtags.NXB_HIST_TAGS if tg in c.hist)
    res.checks.append("histograms: %d, every one sums to its row's reps unless listed" % nh)

    # Harness removed (the plan's execution amendment).
    rsec_m = _mean(c.t["RSEC"] for c in clips if "RSEC" in c.t)
    rcol_m = _mean(c.t["RCOL"] for c in clips if "RCOL" in c.t)
    for c in clips:
        t, p = c.t, c.p
        rsec = t.get("RSEC", rsec_m)
        rcol = t.get("RCOL", rcol_m)
        if "RSEC" not in t and "ARSE" in t:
            c.notes.append("ARSE' uses the mean RSEC (this clip's RSEC is not usable)")
        if "RCOL" not in t and "ARCO" in t:
            c.notes.append("ARCO' uses the mean RCOL (this clip's RCOL is not usable)")
        if "RSEC" in t:
            p["RSEC"] = t["RSEC"] - H_CARD
        if "RCOL" in t:
            p["RCOL"] = t["RCOL"] - H_CARD
        if "ARSE" in t:
            p["ARSE"] = t["ARSE"] - H_CARD * t["ARSE"] / rsec
        if "ARCO" in t:
            p["ARCO"] = t["ARCO"] - H_CARD * t["ARCO"] / rcol
        if "RSWP" in t:
            p["RSWP"] = t["RSWP"] - G_FRAME
            if "ARSW" in t:
                p["ARSW"] = t["ARSW"] - G_FRAME * t["ARSW"] / t["RSWP"]
        elif "ARSW" in t:
            c.notes.append("ARSW' not formed: RSWP is not usable")
        if "RFR0" in t:
            p["RFR0"] = t["RFR0"] - G_FRAME

    # Consistency checks before the fit.
    for tg in ("RSEC", "RCOL", "RHST", "SPN0", "OSPN"):
        _peer(res, tg + " (all clips)", {c.clip: c.t[tg] for c in clips if tg in c.t})
    _peer(res, "RHST polls (all clips)", {c.clip: sum(b * _bin_polls(k)[0] for k, b in
                                                      enumerate(c.hist["RHST"]))
                                          for c in clips if "RHST" in c.hist})
    for form in FORMS:
        fc = [c for c in clips if c.form == form]
        for tg in ("ARSE", "ARCO", "AHST", "ASPN"):
            _peer(res, "%s (%s)" % (tg, form), {c.clip: c.t[tg] for c in fc if tg in c.t})
        _peer(res, "AHST polls (%s)" % form, {c.clip: sum(b * _bin_polls(k)[0] for k, b in
                                                          enumerate(c.hist["AHST"]))
                                              for c in fc if "AHST" in c.hist})
    for name, a, b in (("RSWP/16 < ARSW/16", "RSWP", "ARSW"), ("RSWP/16 < RFR0", "RSWP", "RFR0")):
        got = [c for c in clips if a in c.t and b in c.t]
        for c in got:
            if not c.t[a] < c.t[b]:
                res.anomalies.append("clip %03d: %s fails (%.2f, %.2f) (RE-RUN)" % (
                    c.clip, name, c.t[a], c.t[b]))
        res.checks.append("order %-22s %d/%d clips" % (
            name, sum(1 for c in got if c.t[a] < c.t[b]), len(got)))

    if clips_dir is not None:
        res.clipfiles = {}
        for c in clips:
            path = Path(clips_dir) / ("%03d.VID" % c.clip)
            if not path.is_file():
                res.clipfiles[c.clip] = None
                continue
            bad, pals, badtags = check_clip_file(path, c.clip)
            res.clipfiles[c.clip] = (bad, pals, badtags)
            for b in bad:
                res.anomalies.append("clip %03d file: %s" % (c.clip, b))
            if badtags:
                res.anomalies.append("clip %03d file: frame tags %r" % (c.clip, badtags))
            if 0 not in pals:
                res.anomalies.append("clip %03d file: frame 0 has no palette sector, RFR0 "
                                     "times none" % c.clip)
            if [i for i in pals if i]:
                res.anomalies.append("clip %03d file: frames %r carry a palette sector inside "
                                     "RSWP/ARSW" % (c.clip, [i for i in pals if i]))

    # The fit (the plan's gate table on the primed figures).
    ts_vals = [c.p["RSEC"] - SECTOR_INI_T for c in clips if "RSEC" in c.p]
    res.ts = _mean(ts_vals)
    for form in FORMS:
        fc = [c for c in clips if c.form == form]
        if not fc:
            raise FitError("no %s clip in the log" % form)
        arse = [c for c in fc if "ARSE" in c.p]
        arse_m = _mean(c.p["ARSE"] for c in arse)
        tb = (arse_m - res.ts) / 512
        tcc = [c for c in fc if "ARSE" in c.p and "ARCO" in c.p]
        tc = _mean((c.p["ARCO"] - c.p["ARSE"]) / COL_ENDS for c in tcc)
        lc = [c for c in fc if "ARSW" in c.p]
        pts = [(c.geo.ssnd, c.p["ARSW"] - c.geo.spix * arse_m - c.geo.cols * tc) for c in lc]
        tf, tsnd = _lsq(pts)
        pc = [c for c in fc if "RFR0" in c.p and "ARSW" in c.p]
        tps = {c.clip: (c.p["RFR0"] - c.p["RSWP"]) * c.p["ARSW"] / c.p["RSWP"] for c in pc}
        res.k[form] = dict(tb=tb, ts=res.ts, tsnd=tsnd, tc=tc, tf=tf, tp=_mean(tps.values()))
        res.src[form] = dict(ts=[c.clip for c in clips if "RSEC" in c.p],
                             tb=[c.clip for c in arse], tc=[c.clip for c in tcc],
                             lsq=[c.clip for c in lc], tp=[c.clip for c in pc])
        res.tps[form] = tps
        res.lsq[form] = [(c.clip, x, y) for c, (x, y) in zip(lc, pts)]
        res.duty[form] = _mean(c.t["ARSE"] / c.t.get("RSEC", rsec_m) for c in arse)

    # Residuals and acceptance.
    for c in clips:
        if "ARSW" not in c.p:
            continue
        model = nxv2enc.raw_model_t(c.geo.spix, c.geo.ssnd, c.geo.cols, False,
                                    res.k[c.form])["total_t"]
        res.residuals.append(Resid(c.clip, c.form, c.geo.spix, c.geo.ssnd, c.geo.cols,
                                   c.p["ARSW"], model, 100.0 * (c.p["ARSW"] - model) / model))
    res.max_resid = max(abs(r.pct) for r in res.residuals)
    res.accepted = res.max_resid <= ACCEPT_PCT

    # Stall: the highest occupied AHST bin's upper edge, polls scaled by ARSE/RSEC.
    tops = []
    for c in clips:
        bins = c.hist.get("AHST")
        if not bins or not any(bins) or "ARSE" not in c.t:
            continue
        kmax = max(i for i, b in enumerate(bins) if b)
        ratio = c.t["ARSE"] / c.t.get("RSEC", rsec_m)
        tops.append((kmax, _wait_t(wait_shape, _bin_polls(kmax)[1]) * ratio, c.clip))
    if not tops:
        raise FitError("no AHST histogram")
    top = max(k for k, _, _ in tops)
    res.stall, res.stall_top = max((v, (top, clip)) for k, v, clip in tops if k == top)

    def wait_sum(hists):
        return sum(sum(cnt * _wait_t(wait_shape, _bin_polls(k)[2]) for k, cnt in enumerate(b))
                   for b in hists)
    for form in FORMS:
        fc = [c for c in clips if c.form == form]
        ah = [c.hist["AHST"] for c in fc if "AHST" in c.hist]
        n = sum(sum(b) for b in ah)
        res.wait[form] = wait_sum(ah) / n * res.duty[form] if n else None
        res.hsum["AHST " + form] = [sum(b[k] for b in ah) for k in range(nxbtags.NXB_HIST_BINS)]
    rh = [c.hist["RHST"] for c in clips if "RHST" in c.hist]
    n = sum(sum(b) for b in rh)
    res.wait["unarmed"] = wait_sum(rh) / n if n else None
    res.hsum["RHST"] = [sum(b[k] for b in rh) for k in range(nxbtags.NXB_HIST_BINS)]

    # First poll at the production spacing against the prototype's 39 T: the same clips'
    # RHST/RH39 and AHST/AH39 bins, mean $FF polls a wait. Printed only, in no constant.
    def mean_polls(hists):
        n = sum(sum(b) for b in hists)
        return sum(sum(cnt * _bin_polls(k)[2] for k, cnt in enumerate(b)) for b in hists) / n
    for base, alt, forms in (("RHST", "RH39", (None,)), ("AHST", "AH39", FORMS)):
        for form in forms:
            fc = [c for c in clips if base in c.hist and alt in c.hist
                  and form in (None, c.form)]
            if not fc:
                continue
            key = alt if form is None else "%s %s" % (alt, form)
            res.hsum[key] = [sum(c.hist[alt][k] for c in fc)
                             for k in range(nxbtags.NXB_HIST_BINS)]
            res.cmp39[key] = (mean_polls([c.hist[base] for c in fc]),
                              mean_polls([c.hist[alt] for c in fc]), len(fc))

    # Handler cost per interrupt: (armed - SPN0) / (armed rep T / CTC period).
    groups = {"stereo": ("ASPN", "stereo"), "mono": ("ASPN", "mono"), "old": ("OSPN", None)}
    for name, (tg, form) in groups.items():
        hc = [c for c in clips if tg in c.t and "SPN0" in c.t and form in (None, c.form)]
        vals = [(c.t[tg] - c.t["SPN0"]) * res.period / c.t[tg] for c in hc]
        res.handler[name] = _mean(vals)
        res.handler_spread[name] = (min(vals), max(vals), len(vals))
        res.handler_n[name] = _mean(c.t[tg] / res.period for c in hc)
    # Per clip: a stereo/mono twin with the wrong channel label shows the other handler.
    hcs = {c.clip: (c.t["ASPN"] - c.t["SPN0"]) * res.period / c.t["ASPN"]
           for c in clips if "ASPN" in c.t and "SPN0" in c.t}
    res.handler_clip = hcs
    for form in FORMS:
        _peer(res, "handler (%s)" % form, {k: v for k, v in hcs.items()
                                           if res.clips[k].form == form})
    for k, v in sorted(hcs.items()):
        own, other = res.clips[k].form, FORMS[1 - FORMS.index(res.clips[k].form)]
        if abs(v - res.handler[other]) < abs(v - res.handler[own]):
            res.anomalies.append("clip %03d: handler %.1f T is nearer the %s figure %.1f T "
                                 "than the %s %.1f T: channel label? (RE-RUN)" % (
                                     k, v, other, res.handler[other], own, res.handler[own]))
    res.col_unarmed = _mean((c.t["RCOL"] - c.t["RSEC"]) / COL_ENDS
                            for c in clips if "RCOL" in c.t and "RSEC" in c.t)
    res.pad = pad_aware(res)
    res.sound = sound_rule(res, res.pad)
    res.sound_ok = res.sound[0]
    return res


def exit_status(res):
    """0 when acceptance and the sound-term rule pass and no row is listed for a RE-RUN."""
    return 0 if res.accepted and res.sound_ok and not res.anomalies else 1


def asm_line(label):
    """1-based line of a label in src/video.asm; parent.local for a local label."""
    lines = (REPO / "src" / "video.asm").read_text(encoding="latin-1").splitlines()
    parent, _, local = label.partition(".")
    i = next(n for n, l in enumerate(lines) if l.startswith(parent + ":"))
    if local:
        i = next(n for n in range(i + 1, len(lines)) if lines[n].startswith("." + local + ":"))
    return i + 1


def utilisation(res, w, h, fps, form, stall=0.0, palette=True):
    """Worst frame (palette sector unless palette=False) plus glue over the sound period,
    samples x CTC period: the frame loop releases on sound consumption (vid_pace_poll)."""
    g = geometry(w, h, fps, 2 if form == "stereo" else 1)
    m = nxv2enc.raw_model_t(g.spix, g.ssnd, g.cols, palette, res.k[form], 1.0, stall)
    total = m["total_t"] + GLUE_T
    period = g.samples * res.period
    return SimpleNamespace(geo=g, terms=m, model=m["total_t"], total=total, period=period,
                           util=total / period, ref_period=PERIOD_NUM / fps,
                           ref_util=total * fps / PERIOD_NUM)


def largest_height(res, w, fps, form, palette=True):
    """(height, util) of the tallest admitted picture of width w, heights 256 down to 1."""
    for h in range(256, 0, -1):
        try:
            u = utilisation(res, w, h, fps, form, palette=palette)
        except SystemExit:
            continue
        if u.util <= 1.0:
            return h, u.util
    return 0, None


def d_determined(res, form):
    """d is fixed only by clips of one Ssnd with different sound bytes; else bytes track Ssnd."""
    by = {}
    for c, s, _ in res.lsq[form]:
        by.setdefault(s, set()).add(res.clips[c].geo.real)
    return any(len(v) > 1 for v in by.values())


def pad_aware(res):
    """Diagnostic: y = A + S x Ssnd + d x real bytes on the gate fit's points, all three free
    per form; stereo also with d = mono d x armed ratio. "use" maps a form to the fit the
    sound-term rule takes: its own when d_determined; else stereo the scaled fit while mono's d
    is determined; else None (no fit: the rule reads NOT DETERMINED)."""
    import numpy as np
    out = {}
    for form in FORMS:
        pts = [(s, y, res.clips[c].geo.real) for c, s, y in res.lsq[form]]
        a = np.array([[1, s, r] for s, _, r in pts], float)
        b = np.array([y for _, y, _ in pts])
        x = np.linalg.lstsq(a, b, rcond=None)[0]
        out[form] = dict(A=x[0], S=x[1], d=x[2], cond=np.linalg.cond(a), resid=a @ x - b,
                         determined=d_determined(res, form))
    am = {f: res.period / (res.period - res.handler[f]) for f in FORMS}
    d = out["mono"]["d"] * am["stereo"] / am["mono"]
    pts = [(s, y - d * res.clips[c].geo.real) for c, s, y in res.lsq["stereo"]]
    a0, s0 = _lsq(pts)
    out["stereo_d"] = dict(A=a0, S=s0, d=d, resid=[a0 + s0 * s - y for s, y in pts])
    use = {"mono": "mono" if out["mono"]["determined"] else None}
    use["stereo"] = ("stereo" if out["stereo"]["determined"] else
                     "stereo_d" if use["mono"] else None)
    out["use"] = use
    return out


def sound_rule(res, pa):
    """-> (ok, rows, worst d, worst err %, verdict): gate Ssnd x tsnd + tf against each form's
    used pad-aware fit at 256x192 for SOUND_FPS; rows (form, fps, geo, gate, fit, err %, fitted).
    verdict PASS, FAIL, or NOT DETERMINED (a form with no fit to use; ok is False)."""
    fitted = {f: {res.clips[c].shape[2] for c, _, _ in res.lsq[f]} for f in FORMS}
    rows, worst = [], 0.0
    for form, ch in (("mono", 1), ("stereo", 2)):
        if pa["use"][form] is None:
            continue
        fa = pa[pa["use"][form]]
        for fps in SOUND_FPS:
            try:
                g = geometry(256, 192, fps, ch)
            except SystemExit:
                continue
            gate = g.ssnd * res.k[form]["tsnd"] + res.k[form]["tf"]
            fit_t = fa["A"] + fa["S"] * g.ssnd + fa["d"] * g.real
            pct = 100.0 * (gate - fit_t) / (g.samples * res.period)
            worst = max(worst, abs(pct))
            rows.append((form, fps, g, gate, fit_t, pct, fps in fitted[form]))
    dmax = max((abs(pa[pa["use"][f]]["d"]) for f in FORMS if pa["use"][f]), default=0.0)
    if None in pa["use"].values():
        return False, rows, dmax, worst, "NOT DETERMINED"
    ok = dmax <= SOUND_D_MAX and worst <= SOUND_ERR_PCT
    return ok, rows, dmax, worst, "PASS" if ok else "FAIL"


def read_playback(path):
    """Leg B readouts: the first table with Step, Clip and PLAY columns; rows whose Clip is
    a 3-digit number and PLAY 4 hex digits -> [{column: cell}]."""
    head, out = None, []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line.startswith("|"):
            if head is not None:
                break
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if head is None:
            if {"Step", "Clip", "PLAY"} <= set(cells):
                head = cells
            continue
        row = dict(zip(head, cells))
        if re.fullmatch(r"\d{3}", row.get("Clip", "")) and \
                re.fullmatch(r"[0-9A-F]{4}", row.get("PLAY", "")):
            out.append(row)
    return out


def frm_frames(r):
    """Frames a session delivered: the larger FRM half (live/mirror; a counter fault zeroes
    one half of a session that ran, as 0000/00FA)."""
    return max(int(h, 16) for h in r["FRM"].split("/"))


def unscored_reason(r):
    """Why a readout row is left out of the verdict, or None: no LATE, URUN or FRM figure
    ("-": a cut capture, or a -BenchQuiet report, which has no LATE row), or a session that
    ended at once (both FRM halves 1 or less). The capture's LATE and URUN follow when
    present."""
    seen = [k for k in ("LATE", "URUN") if re.fullmatch(r"[0-9A-F]{4}", r.get(k, ""))]
    if len(seen) < 2 or not re.fullmatch(r"[0-9A-F]{4}/[0-9A-F]{4}", r.get("FRM", "")):
        why = "no LATE, URUN or FRM figure (a cut capture, or a -BenchQuiet report)"
    elif frm_frames(r) <= 1:
        why = "ended at once (FRM %s)" % r["FRM"]
    else:
        return None
    return why + "".join(("; " if i == 0 else " ") + "%s %s" % (k, r[k])
                         for i, k in enumerate(seen))


def _fmt_shape(w, h, fps):
    return "%dx%d@%g" % (w, h, fps)


def report(res, readouts=None):
    o = []
    add = o.append
    pre, tc, nr11 = res.ctc
    add("raw_fit: %s" % res.log)
    add("timing: +3, %d lines x %d T a field (parse.timing); T = (F x %d + D) x %d" % (
        LPF, T_LINE, LPF, T_LINE))
    add("CTC 0 period: %d x %d = %d T (AUD_CTC_CW16 prescaler, vidCtcTcNxvStereo[NR $11 = %d])"
        % (pre, tc, res.period, nr11))
    add("harness: card h = %d T a rep, frame g = %d T a frame (nxv2_bench_rows, model %s)" % (
        H_CARD, G_FRAME, next(m for m, g in MODEL_G_FRAME.items() if g == G_FRAME)))
    add("")
    add("## Sections")
    add("")
    secs = []
    for c in res.clips.values():
        w, h, fps, ch, _ = c.shape
        secs.append((c.section, "%2d #NXB %04X NXBW clip %03d %s %s: %d rows, %d histograms" % (
            c.section, c.stamp, c.clip, c.form, _fmt_shape(w, h, fps), len(c.rows),
            len(c.hist))))
    for x in res.excluded:
        stale = FAIL_RE.match(x.failure) is not None
        secs.append((x.section, "%2d #NXB %04X %s clip %s: EXCLUDED - %s%s" % (
            x.section, x.stamp, x.verb, x.clip, x.failure,
            " (an open failure: the rows on screen are the previous session's)" if stale
            else "")))
    if res.old is not None:
        secs.append((res.old.index, "%2d #NXB %04X NXBD clip %s: old direct rows (%d)" % (
            res.old.index, res.old.stamp, res.old.clip, len(res.old.rows))))
    for _, line in sorted(secs):
        add(line)
    for n in res.notes:
        add("note: " + n)
    add("")
    add("## Decoded rows")
    add("")
    add("T/rep = (F x %d + D) x %d / R. Primed (harness removed): RSEC' = RSEC - h, "
        "RCOL' = RCOL - h, ARSE' = ARSE - h x ARSE/RSEC, ARCO' = ARCO - h x ARCO/RCOL, "
        "RSWP' = RSWP/16 - g, ARSW' = ARSW/16 - g x ARSW/RSWP, RFR0' = RFR0 - g." % (
            LPF, T_LINE))
    for c in sorted(res.clips.values(), key=lambda c: c.clip):
        w, h, fps, ch, _ = c.shape
        add("")
        add("clip %03d %s %s: Spix %d, Ssnd %d, C %d (section %d)" % (
            c.clip, c.form, _fmt_shape(w, h, fps), c.geo.spix, c.geo.ssnd, c.geo.cols,
            c.section))
        add("")
        add("| tag | O | R | F | D | lines | T | T/rep | primed |")
        add("|---|---|---|---|---|---|---|---|---|")
        for tg in shape_tags(res, RW1_TAGS):
            row = c.rows.get(tg)
            if row is None:
                add("| %s | missing | | | | | | | |" % tg)
                continue
            o_, r, f, d = row
            if tg == "IDEN":
                add("| IDEN | %02X | %d | %d | %d | | | | |" % (o_, r, f, d & 0xFF))
                continue
            lines = f * LPF + d
            per = c.t.get(tg)
            pr = c.p.get(tg)
            flag = "" if per is not None else " excluded"
            add("| %s | %02X | %d | %d | %d | %d | %d | %s | %s |" % (
                tg, o_, r, f, d, lines, row_t(row), "-" if per is None else "%.2f" % per,
                ("%.2f" % pr if pr is not None else "-") + flag))
        for tg in nxbtags.NXB_HIST_TAGS:
            b = c.hist.get(tg)
            if b:
                add("")
                add("#HIST %s: %s" % (tg, ", ".join("bin %d = %d" % (k, v)
                                                    for k, v in enumerate(b) if v)))
        for n in c.notes:
            add("note: " + n)
    add("")
    add("## Checks")
    add("")
    add("- IDEN (O, frames, width, height byte) matches the fixture table on every used "
        "capture (a mismatch excludes the capture, listed above)")
    if res.clipfiles is None:
        add("- clip files: not checked (no --clips)")
    else:
        for clip in sorted(res.clipfiles):
            v = res.clipfiles[clip]
            if v is None:
                add("- clip %03d file: absent, not checked" % clip)
            else:
                bad, pals, badtags = v
                c = res.clips[clip]
                add("- clip %03d file: header %s (channels %d, sound bytes %d, Ssnd %d); "
                    "palette sectors in frames 0-32: %s" % (
                        clip, "matches" if not bad else "MISMATCH " + "; ".join(bad),
                        c.shape[3], c.geo.real, c.geo.ssnd,
                        ", ".join(str(i) for i in pals) or "none"))
    for line in res.checks:
        add("- " + line)
    add("- walk marks (O=01): %s" % (", ".join("clip %03d %s" % w for w in res.walked)
                                     or "none"))
    add("")
    add("Anomalies (RE-RUN request):" + ("" if res.anomalies else " none"))
    for a in res.anomalies:
        add("- " + a)
    add("")
    add("## Constants")
    add("")
    add("RAW_SECTOR_T (ts) = %.2f T: mean (RSEC' - 8192) over %d clips [RSEC]" % (
        res.ts, len(res.src[FORMS[0]]["ts"])))
    for form in FORMS:
        k, s = res.k[form], res.src[form]
        add("")
        add("%s:" % form)
        add("  RAW_T_PER_B (tb)      = %.4f T: (mean ARSE' - ts) / 512 over %d clips "
            "[ARSE, RSEC]" % (k["tb"], len(s["tb"])))
        add("  RAW_COL_T (tc)        = %.2f T: mean (ARCO' - ARSE') / 8 over %d clips "
            "[ARCO, ARSE, RCOL, RSEC]" % (k["tc"], len(s["tc"])))
        add("  RAW_SND_SECTOR_T (tsnd) = %.2f T: least squares slope over %d clips "
            "[ARSW, RSWP, ARSE, ARCO]" % (k["tsnd"], len(s["lsq"])))
        add("  RAW_FRAME_T (tf)      = %.2f T: least squares intercept, same points" % k["tf"])
        add("  RAW_PAL_T (tp)        = %.2f T: mean (RFR0' - RSWP') x ARSW'/RSWP' over %d "
            "clips [RFR0, RSWP, ARSW]" % (k["tp"], len(s["tp"])))
        add("  least squares points (clip, Ssnd, y = ARSW' - Spix x mean ARSE' - C x tc): "
            + "; ".join("%03d %d %.1f" % p for p in res.lsq[form]))
        add("  tp per clip: " + "; ".join("%03d %.1f" % kv for kv in sorted(
            res.tps[form].items())))
        add(sound_note(res, form))
    top, sclip = res.stall_top
    lo, hi, _ = _bin_polls(top)
    p1, p = WAIT_SHAPES[res.wait_shape]
    if hi == 0:
        edge = "0 T (the token on poll 1)"
    elif p1 == p:
        edge = "%d x %d T" % (hi, p)
    else:
        edge = "%d polls (%d + %d x %d T)" % (hi, p1, p, hi - 1)
    add("")
    add("RAW_STALL_T = %.2f T: highest occupied AHST bin %d (%d-%d polls), upper edge %s "
        "x ARSE/RSEC (clip %03d) [AHST, ARSE, RSEC]" % (res.stall, top, lo, hi, edge, sclip))
    add("mean token wait (bins at their mean poll count): unarmed %.2f T [RHST]; armed "
        "stereo %.2f T, mono %.2f T [AHST x ARSE/RSEC]" % (
            res.wait["unarmed"], res.wait["stereo"], res.wait["mono"]))
    add("mean stall per frame = armed mean wait x tokens a frame (Spix + Ssnd + 1):")
    for w, h, fps in TARGETS:
        cells = []
        for form in FORMS:
            g = geometry(w, h, fps, 2 if form == "stereo" else 1)
            cells.append("%s %.0f T (%d tokens)" % (form, res.wait[form] * (g.spix + g.ssnd + 1),
                                                   g.spix + g.ssnd + 1))
        add("  %s: %s" % (_fmt_shape(w, h, fps), ", ".join(cells)))
    add("")
    add("Paste form:")
    add("")
    add("```")
    add("RAW_K = {")
    for form in FORMS:
        k, s = res.k[form], res.src[form]
        add('    "%s": {' % form)
        add('        "tb": %.4f,  # RAW_T_PER_B [ARSE, RSEC] %d clips' % (k["tb"], len(s["tb"])))
        add('        "ts": %.2f,  # RAW_SECTOR_T [RSEC] %d clips' % (k["ts"], len(s["ts"])))
        add('        "tsnd": %.2f,  # RAW_SND_SECTOR_T [ARSW, RSWP, ARSE, ARCO] %d clips' % (
            k["tsnd"], len(s["lsq"])))
        add('        "tc": %.2f,  # RAW_COL_T [ARCO, ARSE, RCOL, RSEC] %d clips' % (
            k["tc"], len(s["tc"])))
        add('        "tf": %.2f,  # RAW_FRAME_T [ARSW, RSWP, ARSE, ARCO] %d clips' % (
            k["tf"], len(s["lsq"])))
        add('        "tp": %.2f,  # RAW_PAL_T [RFR0, RSWP, ARSW] %d clips' % (k["tp"],
                                                                         len(s["tp"])))
        add("    },")
    add("}")
    add("RAW_STALL_T = %.2f  # AHST bin %d upper edge x ARSE/RSEC [AHST, ARSE, RSEC]" % (
        res.stall, top))
    add("```")
    add("")
    add("## Residuals")
    add("")
    add("residual = 100 x (measured - model) / model; measured = ARSW' (ARSW/16, harness "
        "removed); model = raw_model_t(..., palette=False). Acceptance: every |residual| "
        "<= %.1f%%." % ACCEPT_PCT)
    add("")
    add("| clip | form | Spix | Ssnd | C | sound B | pad B | measured ARSW' | model | "
        "residual % |")
    add("|---|---|---|---|---|---|---|---|---|---|")
    for r in res.residuals:
        g = res.clips[r.clip].geo
        add("| %03d | %s | %d | %d | %d | %d | %d | %.1f | %.1f | %+.3f |" % (
            r.clip, r.form, r.spix, r.ssnd, r.cols, g.real, g.padded - g.real, r.meas,
            r.model, r.pct))
    add("")
    add("pad B: the sound sectors' pad bytes a frame, the tag byte included.")
    add("")
    add("acceptance: %s (largest |residual| %.3f%%)" % (
        "PASS" if res.accepted else "FAIL", res.max_resid))
    add("")
    add("## Sound term (diagnostic; the gate is unchanged)")
    add("")
    for form in FORMS:
        add("- " + sound_note(res, form)[len("note: "):])
    pa = res.pad
    m, s, s2 = pa["mono"], pa["stereo"], pa["stereo_d"]
    add("- pad-aware fit y = A + S x Ssnd + d x real bytes, on the gate fit's points (d: T a "
        "sound byte costs over a pad byte):")
    for form, f in (("mono", m), ("stereo", s)):
        add("  - %s, all three free: A %.1f, S %.1f, d %+.2f T a sound byte (condition number "
            "%.0f; %s); residuals %s T" % (
                form, f["A"], f["S"], f["d"], f["cond"],
                "d determined: one Ssnd group holds two sound-byte counts" if f["determined"]
                else "d not determined: the clips' sound bytes, %s, track Ssnd" % ", ".join(
                    "%d" % b for b in sorted({res.clips[c].geo.real for c, _, _ in
                                              res.lsq[form]})),
                " ".join("%+.0f" % v for v in f["resid"])))
    if m["determined"]:
        add("  - stereo with d = mono d x armed ratio = %+.2f: A %.1f, S %.1f; residuals %s T" % (
            s2["d"], s2["A"], s2["S"], " ".join("%+.0f" % v for v in s2["resid"])))
    else:
        add("  - stereo with d = mono d x armed ratio: not formed (mono d not determined)")
    add("  - code: the raw pump (vrPumpT, video.asm:%d) reads sound, pad and tag through the "
        "INI slide, 16 T a byte; sitting 1b's images read the pad and tag by the slide and a "
        "sound byte by vid_ds_xfer (video.asm:%d), 16 T plus 14 T a 32-byte pass and about "
        "300 T an arm, about 17.6 T in 256-byte arms: a sound byte about 1.6 T over a pad "
        "byte there, unarmed" % (asm_line("vrPumpT"), asm_line("vid_ds_xfer")))
    add("- mono RAW_FRAME_T %.2f T, mono RAW_SND_SECTOR_T %.2f T (%.2f x stereo's %.2f T)." % (
        res.k["mono"]["tf"], res.k["mono"]["tsnd"],
        res.k["mono"]["tsnd"] / res.k["stereo"]["tsnd"], res.k["stereo"]["tsnd"]))
    add("")
    ok, rows, dmax, worst_all, verdict = res.sound
    add("gate sound term (Ssnd x tsnd + tf) against the pad-aware fit, 256x192 (mono: %s; "
        "stereo: %s); err = gate - fit, negative = the gate under-prices:" % tuple(
            "its own fit" if pa["use"][f] == f else "d scaled from mono" if pa["use"][f]
            else "d not determined" for f in FORMS[::-1]))
    add("")
    add("| form | fps | sound B | Ssnd | pad B | gate T | fit T | err T | err % of period | "
        "fitted pair |")
    add("|---|---|---|---|---|---|---|---|---|---|")
    worst = 0.0
    for form, fps, g, gate, fit_t, pct, fitted in rows:
        if not fitted:
            worst = max(worst, abs(pct))
        add("| %s | %g | %d | %d | %d | %.0f | %.0f | %+.0f | %+.3f | %s |" % (
            form, fps, g.real, g.ssnd, g.padded - g.real, gate, fit_t, gate - fit_t, pct,
            "yes" if fitted else "no"))
    add("")
    add("largest |err| outside the fitted pairs: %.3f percent of the period" % worst)
    none = [f for f in FORMS[::-1] if pa["use"][f] is None]
    add("sound-term rule (one term a sector holds: |d| <= %.1f T a sound byte in both forms and "
        "every layout above within %.2f percent): %s" % (SOUND_D_MAX, SOUND_ERR_PCT, verdict)
        + (" (%s: %s sound bytes track Ssnd)" % (", ".join(f + " d" for f in none),
                                                 "its" if len(none) == 1 else "their") if none
           else " (largest |d| %.2f T, largest |err| %.3f percent)" % (dmax, worst_all)))
    add("")
    add("## Utilisation of the target shapes")
    add("")
    add("period = samples a frame x %d T: vid_run releases a frame when the CTC reader has "
        "consumed the previous frame's sound (vid_pace_poll at .pace, video.asm:%d; the "
        "deficit clamp at .paced, video.asm:%d), not on fields. Worst frame (palette sector) "
        "+ glue %.1f T (glue_t / audio_factor); F = 1.0. The last column is the two-field "
        "period %d / fps, for reference only." % (
            res.period, asm_line("vid_run.pace"), asm_line("vid_run.paced"), GLUE_T,
            PERIOD_NUM))
    add("")
    add("| shape | form | Spix | Ssnd | C | model T | period T | util | util with stall | "
        "util, pixels-only frame | ref: util at two fields |")
    add("|---|---|---|---|---|---|---|---|---|---|---|")
    over, near = {f: [] for f in FORMS}, {f: [] for f in FORMS}
    for w, h, fps in TARGETS:
        for form in FORMS:
            u0 = utilisation(res, w, h, fps, form)
            u1 = utilisation(res, w, h, fps, form, res.stall)
            up = utilisation(res, w, h, fps, form, palette=False)
            add("| %s | %s | %d | %d | %d | %.0f | %.0f | %.4f | %.4f | %.4f | %.4f |" % (
                _fmt_shape(w, h, fps), form, u0.geo.spix, u0.geo.ssnd, u0.geo.cols, u0.model,
                u0.period, u0.util, u1.util, up.util, u0.ref_util))
            for u, tag in ((u0, ""), (u1, " (with stall)")):
                if u.util > 1.0:
                    over[form].append(_fmt_shape(w, h, fps) + tag)
                elif u.util > NEAR_UTIL:
                    near[form].append(_fmt_shape(w, h, fps) + tag)
    add("")
    for form in FORMS:
        add("%s over 1.00: %s" % (form, ", ".join(over[form]) or "none"))
        add("%s within 10 percent of the limit (0.90 < util <= 1.00): %s" % (
            form, ", ".join(near[form]) or "none"))
    add("")
    add("## Largest admitted height at 25 fps")
    add("")
    add("Heights 256 down to 1, util <= 1.00 at the sound period, glue added, F = 1.0.")
    add("")
    add("| width | form | palette frame: height | util | pixels-only frame: height | util |")
    add("|---|---|---|---|---|---|")
    for w in (320, 280, 256):
        for form in FORMS:
            h0, u0 = largest_height(res, w, 25, form)
            h1, u1 = largest_height(res, w, 25, form, palette=False)
            add("| %d | %s | %d | %.4f | %d | %.4f |" % (w, form, h0, u0, h1, u1))
    add("")
    add("## Budget of a 320x192@25 frame")
    add("")
    period = 625 * res.period
    add("Period %d T (625 samples x %d T). Palette frame, F = 1.0." % (period, res.period))
    add("")
    add("| term | stereo T | stereo % | mono T | mono % |")
    add("|---|---|---|---|---|")
    us = {f: utilisation(res, 320, 192, 25, f) for f in FORMS}
    hand = {f: us[f].terms["byte_t"] / res.period * res.handler[f] for f in FORMS}
    rows = (("pixel bytes, Spix x 512 x tb", "byte_t"),
            ("  of which the sound handler: (byte T / %d) interrupts x handler T" % res.period,
             None),
            ("per-sector overhead, Spix x ts", "sector_t"), ("column ends, C x tc", "col_t"),
            ("sound sectors, Ssnd x tsnd", "snd_t"), ("frame remainder, tf", "frame_t"),
            ("palette sector, tp", "pal_t"), ("glue", "glue"), ("total", "total"))
    for name, key in rows:
        cells = []
        for f in FORMS:
            u = us[f]
            v = (hand[f] if key is None else GLUE_T if key == "glue" else
                 u.total if key == "total" else u.terms[key])
            cells += ["%.0f" % v, "%.2f" % (100.0 * v / period)]
        add("| %s | %s |" % (name, " | ".join(cells)))
    add("")
    for f in FORMS:
        add("- %s handler: one interrupt a sample, 625 a frame, %.2f T each = %.0f T a frame "
            "(%.2f percent of the period, all terms together)" % (
                f, res.handler[f], 625 * res.handler[f], 100.0 * res.handler[f] / res.period))
    add("- 1.0 percent of a 25 fps period is %.0f T a frame." % (period / 100.0))
    add("")
    add("## Handlers, sectors, column ends")
    add("")
    add("handler cost per interrupt = (armed - SPN0) / interrupts a rep; interrupts a rep = "
        "armed rep T / %d T" % res.period)
    for name, label in (("stereo", "raw stereo (ASPN, stereo clips)"),
                        ("mono", "raw mono (ASPN, mono clips)"),
                        ("old", "existing video_ctc_isr_stereo (OSPN, all clips)")):
        lo, hi, n = res.handler_spread[name]
        add("- %s: %.2f T (%.2f interrupts a rep; %d clips, %.2f-%.2f)" % (
            label, res.handler[name], res.handler_n[name], n, lo, hi))
    clips = list(res.clips.values())
    rsec_m = _mean(c.t["RSEC"] for c in clips if "RSEC" in c.t)
    add("- per-sector overhead, unarmed: ts = %.2f T (RSEC - 8192 as printed: %.2f T)" % (
        res.ts, rsec_m - SECTOR_INI_T))
    for form in FORMS:
        fc = [c for c in clips if c.form == form and "ARSE" in c.p]
        add("- per-sector overhead, armed %s: ARSE' - 8192 = %.2f T (ARSE as printed %.2f T, "
            "ARSE/RSEC %.4f)" % (form, _mean(c.p["ARSE"] for c in fc) - SECTOR_INI_T,
                                 _mean(c.t["ARSE"] for c in fc), res.duty[form]))
    add("- column end, unarmed: (RCOL - RSEC) / 8 = %.2f T against the %d T design figure"
        % (res.col_unarmed, COL_END_DESIGN_T))
    for form in FORMS:
        add("- column end, armed %s: tc = %.2f T" % (form, res.k[form]["tc"]))
    add("")
    add("## Histograms (summed over clips)")
    add("")
    if p1 == p:
        add("bin k counts token waits of 2^(k-1) to 2^k - 1 $FF polls (bin 0: the token on the "
            "first read); a poll is %d T unarmed, %d x ARSE/RSEC armed." % (p, p))
    else:
        add("bin k counts token waits of 2^(k-1) to 2^k - 1 $FF polls (bin 0: the token on the "
            "first read; bin %d: 256 or more); n polls wait %d + %d x (n - 1) T unarmed, that x "
            "ARSE/RSEC armed (wait shape %s)." % (HIST_BIN_LONG, p1, p, res.wait_shape))
    add("")
    add("| histogram | bin | polls | wait T | count |")
    add("|---|---|---|---|---|")
    for name, bins in res.hsum.items():
        scale = 1.0 if name in ("RHST", "RH39") else res.duty[name.split()[1]]
        for k, cnt in enumerate(bins):
            if cnt:
                lo, hi, _ = _bin_polls(k)
                add("| %s | %d | %d-%d | %.1f-%.1f | %d |" % (
                    name, k, lo, hi, _wait_t(res.wait_shape, lo) * scale,
                    _wait_t(res.wait_shape, hi) * scale, cnt))
        add("| %s | all | | | %d |" % (name, sum(bins)))
    add("")
    if res.cmp39:
        add("First poll at the benched image's production spacing (RHST/AHST: 11 + 7 x "
            "VR_POLL_PAD_N T after CRC 2; the log does not record VR_POLL_PAD_N) against the "
            "prototype's 39 T (RH39/AH39), the same clips, mean $FF polls a wait (bins at "
            "their mean): %s. Used in no constant; the wait T columns above count from poll 1 "
            "for both." % ("; ".join(
                "%s %.3f against %.3f (%d clips)" % (
                    "unarmed" if k == "RH39" else "armed " + k.split()[1], a, b, n)
                for k, (a, b, n) in res.cmp39.items())))
        add("")
    add("## Old layout vs raw")
    add("")
    if res.old is None:
        add("no NXBD capture in the log")
    else:
        ot = {tg: row_t(r) / r[1] for tg, r in res.old.rows.items()
              if tg in ("DTI0", "DTB0", "DTC0", "DTD0", "ADTI", "ADTC")}
        fm = {f: [c for c in clips if c.form == f and "ARSE" in c.t] for f in FORMS}
        ar = {f: _mean(c.t["ARSE"] for c in fm[f]) for f in FORMS}
        rcol_m = _mean(c.t["RCOL"] for c in clips if "RCOL" in c.t)
        add("old: NXBD on clip %s (old direct layout), per block, rows as printed (the DS1 "
            "harness is not tracked); raw: RW1 means, per sector, as printed." % res.old.clip)
        add("")
        add("| what | old row | old T | raw row | raw T |")
        add("|---|---|---|---|---|")

        def g(tg):
            return "%.2f" % ot[tg] if tg in ot else "missing"
        add("| open + 512 bare INI, unarmed | DTI0 | %s | RSEC | %.2f |" % (g("DTI0"), rsec_m))
        add("| open + 512 bare INI, armed | ADTI (old handler) | %s | ARSE stereo / mono "
            "(raw handlers) | %.2f / %.2f |" % (g("ADTI"), ar["stereo"], ar["mono"]))
        add("| open + 512 B to the destination, unarmed | DTC0 (vid_ds_xfer) | %s | RSEC "
            "(the slide is the transfer) | %.2f |" % (g("DTC0"), rsec_m))
        add("| open + 512 B to the destination, armed | ADTC (old handler) | %s | ARSE stereo "
            "/ mono | %.2f / %.2f |" % (g("ADTC"), ar["stereo"], ar["mono"]))
        add("| open + split transfer | DTD0 (4 x xfer 128) | %s | RCOL (8 x 64, column ends) "
            "| %.2f |" % (g("DTD0"), rcol_m))
        add("| open + pad discard | DTB0 (vid_ds_pad) | %s | - (raw pad bytes are INI) | - |"
            % g("DTB0"))
        if "DTI0" in ot:
            add("| per-block overhead, unarmed | DTI0 - 8192 | %.2f | RSEC - 8192 (ts) | "
                "%.2f (%.2f) |" % (ot["DTI0"] - SECTOR_INI_T, rsec_m - SECTOR_INI_T, res.ts))
        if "ADTC" in ot:
            add("| T per byte, armed, transfer included | ADTC / 512 | %.3f | ARSE / 512 stereo "
                "/ mono | %.3f / %.3f |" % (ot["ADTC"] / 512, ar["stereo"] / 512,
                                            ar["mono"] / 512))
        add("| gate T per byte | DIRECT_T_PER_B (section byte, wire included) | %.1f | tb "
            "stereo / mono | %.4f / %.4f |" % (nxv2enc.DIRECT_T_PER_B, res.k["stereo"]["tb"],
                                                res.k["mono"]["tb"]))
    add("")
    add("## Playback (leg B)")
    add("")
    shapes = {k: v[:4] for k, v in FIXTURES.items()}
    shapes.update(PLAYBACK_ONLY)
    if not readouts:
        add("no leg B readouts given (--playback); the model's verdict per clip:")
        add("")
        add("| clip | shape | form | util | model |")
        add("|---|---|---|---|---|")
        for clip in sorted(shapes):
            w, h, fps, ch = shapes[clip]
            u = utilisation(res, w, h, fps, form_of(ch), res.stall)
            add("| %03d | %s | %s | %.4f | %s |" % (clip, _fmt_shape(w, h, fps), form_of(ch),
                                                  u.util, "admitted" if u.util <= 1 else
                                                  "refused"))
        return "\n".join(o) + "\n"
    raw, unscored = [], []
    for r in readouts:
        if int(r["Clip"]) not in shapes:
            continue
        why = unscored_reason(r)
        if why:
            unscored.append("not scored: %s %s - %s" % (r["Step"], r["Clip"], why))
        else:
            raw.append(r)
    add("### Step 6: the model's verdict against LATE and URUN")
    add("")
    add("model: the gate (Release instructions, palette frame, stall term) at the sound period; "
        "admitted = util <= 1.00. On time = LATE 0000 and URUN 0000.")
    add("")
    add("| step | clip | shape | form | util | model | LATE | URUN | on time |")
    add("|---|---|---|---|---|---|---|---|---|")
    bad_adm, bad_ref = [], []
    for r in raw:
        clip = int(r["Clip"])
        w, h, fps, ch = shapes[clip]
        u = utilisation(res, w, h, fps, form_of(ch), res.stall)
        ontime = int(r["LATE"], 16) == 0 and int(r["URUN"], 16) == 0
        adm = u.util <= 1.0
        if adm and not ontime:
            bad_adm.append("%s %03d" % (r["Step"], clip))
        if not adm and ontime:
            bad_ref.append("%s %03d" % (r["Step"], clip))
        add("| %s | %03d | %s | %s | %.4f | %s | %s | %s | %s |" % (
            r["Step"], clip, _fmt_shape(w, h, fps), form_of(ch), u.util,
            "admitted" if adm else "refused", r["LATE"], r["URUN"], "yes" if ontime else "no"))
    add("")
    for line in unscored:
        add(line)
    add("admitted clips that showed LATE or URUN: %s" % (", ".join(bad_adm) or "none"))
    add("refused clips that played on time: %s" % (", ".join(bad_ref) or "none"))
    add("fixture clips with no readout row: %s" % (", ".join(
        "%03d" % c for c in sorted(set(shapes) - {int(r["Clip"]) for r in readouts})) or "none"))
    add("readout rows outside the raw model: %s" % (", ".join(sorted(
        {r["Clip"] for r in readouts if int(r["Clip"]) not in shapes})) or "none"))
    add("")
    add("### Late clips: waits for ring room")
    add("")
    add("A frame is released when the CTC reader has consumed the previous frame's sound "
        "(vid_pace_poll at .pace, video.asm:%d); .paced (video.asm:%d) adds one frame's bytes "
        "and drops a deficit of a whole frame. The reader never stops: when the frame loop "
        "runs late it plays on into stale ring bytes and passes the writer. vid_aud_pump's "
        "room test (video.asm:%d: room = ring - guard - (writer - reader) mod ring, with a "
        "%d-byte floor) then sees a nearly full ring, so .qnext (video.asm:%d) leaves the next "
        "frame's sound unwritten and .ffin (video.asm:%d) waits until the reader has freed "
        "room for it, up to one frame period. So a late clip is slowed by more than its "
        "utilisation. The bench rows never see this: nxb_aud_body.ptr (video.asm:%d) puts the "
        "writer half a ring ahead of the reader on every rep. ring_play runs the loop with "
        "the frame work below and counts the waits." % (
            asm_line("vid_run.pace"), asm_line("vid_run.paced"), asm_line("vid_aud_pump.unp"),
            inc_equ("NXV_AUD_PUMP_CHUNK"), asm_line("vid_run.qnext"), asm_line("vid_run.ffin"),
            asm_line("nxb_aud_body.ptr")))
    add("")
    rl = DBG["rl_poll"] / inc_equ("VID_RL_DIV")
    am = {f: res.period / (res.period - res.handler[f]) for f in FORMS}
    add("Frame work = the gate's pixels-only frame + glue + plain DEBUG work (leg B runs the "
        "DEBUG build; IFNDEF NXB_QUIET code the bench image does not carry), on a late "
        "frame's path, base T x the armed factor 1 / (1 - handler / %d) (stereo %.4f, mono "
        "%.4f). Frame 0 adds the palette sector and its DEBUG sector work." % (
            res.period, am["stereo"], am["mono"]))
    if pix_token(res):
        add("- per pixel sector %.1f T: vr_sector_n's PLAY divider %d T (.nocrc, video.asm:%d), "
            "vid_sd_tok_h's poll counter %d T (.got, video.asm:%d), and vid_rl_poll "
            "(video.asm:%d) %d T once per %d arms = %.1f T" % (
                DBG["sector"] + DBG["token"] + rl, DBG["sector"], asm_line("vr_sector_n.nocrc"),
                DBG["token"], asm_line("vid_sd_tok_h.got"), asm_line("vid_rl_poll"),
                DBG["rl_poll"], inc_equ("VID_RL_DIV"), rl))
    else:
        add("- per pixel sector %.1f T: vr_sector_n's PLAY divider %d T (.nocrc, video.asm:%d) "
            "and vid_rl_poll (video.asm:%d) %d T once per %d arms = %.1f T; vid_sd_tok_h's poll "
            "counter (%d T, .got, video.asm:%d) runs only on a wait past the open's djnz loop "
            "(257 or more polls, a RE-RUN), so it is not priced (wait shape %s)" % (
                DBG["sector"] + rl, DBG["sector"], asm_line("vr_sector_n.nocrc"),
                asm_line("vid_rl_poll"), DBG["rl_poll"], inc_equ("VID_RL_DIV"), rl,
                DBG["token"], asm_line("vid_sd_tok_h.got"), res.wait_shape))
    add("- per sound sector %.1f T: vid_ds_blkopen's arm %d T (video.asm:%d), the poll "
        "counter %d T, %.1f T of vid_rl_poll" % (DBG["arm"] + DBG["token"] + rl, DBG["arm"],
                                                 asm_line("vid_ds_blkopen"), DBG["token"], rl))
    add("- per frame: vid_play_frame %d T (video.asm:%d); the .pace poll's arm %d + %.1f T "
        "(vid_pace_poll, video.asm:%d); vid_dbg_late %d T (video.asm:%d); vid_dbg_urun %d T "
        "with its own vid_pace_poll through vid_raw_rd_hl (video.asm:%d) + %.1f T; "
        "vid_aud_pump's .next arm %d + %.1f T a pass (video.asm:%d) x 2 + sound bytes / %d "
        "passes" % (DBG["play_frame"], asm_line("vid_play_frame"), DBG["arm"], rl,
                    asm_line("vid_pace_poll"), DBG["late"], asm_line("vid_dbg_late"),
                    DBG["urun"], asm_line("vid_dbg_urun"), rl, DBG["arm"], rl,
                    asm_line("vid_aud_pump.next"), inc_equ("NXV_AUD_RING")))
    add("- counted from the instructions (Zilog T, NEXTREG A,n read 13 T): every T figure "
        "above. Estimated: the 1-in-%d share of vid_rl_poll at each arm, and the pump passes "
        "a frame (one chunk, a second when the ring tail wraps, the final pass)." %
        inc_equ("VID_RL_DIV"))
    add("")
    ring, guard, chunk = (inc_equ("NXV_AUD_RING"), inc_equ("NXV_AUD_GUARD"),
                          inc_equ("NXV_AUD_PUMP_CHUNK"))
    add("| step | clip | form | frames | DEBUG T a frame | util, pixels-only + DEBUG | PLAY | "
        "on-time PLAY | measured slowdown | predicted PLAY | waits | predicted slowdown | "
        "residual T a frame |")
    add("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in raw:
        clip = int(r["Clip"])
        w, h, fps, ch = shapes[clip]
        form = form_of(ch)
        g = geometry(w, h, fps, ch)
        d = debug_work(res, g, form)
        m0 = nxv2enc.raw_model_t(g.spix, g.ssnd, g.cols, False, res.k[form])["total_t"]
        work = m0 + GLUE_T + d.total
        work0 = work + res.k[form]["tp"] + d.pal
        frames = frm_frames(r)
        per = g.samples * res.period
        tot, waits = ring_play(frames, work, work0, g.real, ch, res.period, ring, guard, chunk)
        play = int(r["PLAY"], 16)
        on = frames * per / FIELD_T
        add("| %s | %03d | %s | %d | %.0f | %.4f | %d | %.1f | %.4f | %.1f | %d | %.4f | %+.0f |"
            % (r["Step"], clip, form, frames, d.total, work / per, play, on, play / on,
               tot / FIELD_T, waits, tot / FIELD_T / on, (play * FIELD_T - tot) / frames))
    add("")
    add("PLAY counts whole fields of %d T: its resolution is %.0f T a frame over 250 frames, "
        "%.0f over 167, %.0f over 125." % (FIELD_T, FIELD_T / 250.0, FIELD_T / 167.0,
                                          FIELD_T / 125.0))
    return "\n".join(o) + "\n"


# ---------------------------------------------------------------------------
# Selftest
# ---------------------------------------------------------------------------

def _near(got, want, pct=0.1):
    return abs(got - want) <= abs(want) * pct / 100.0


def set_model(model):
    """The frame harness the fit and the synthetic rows use: MODEL_G_FRAME[model]."""
    global G_FRAME
    G_FRAME = MODEL_G_FRAME[model]


def selftest():
    fails, checks = [], 0

    def check(ok, what):
        nonlocal checks
        checks += 1
        if not ok:
            fails.append(what)

    pre, tcs = ctc_period()
    per = pre * tcs[0]
    marks = ((64, "ARSE"), (61, "ARSW"))
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "NXBENCH.TXT"
        log.write_bytes(synth_log(marks=marks, stale_after=68).encode("ascii"))
        res = fit(read_sections(log), reps=SYNTH_REPS, wait_shape="inline")
        report(res)
        res_inf = fit(read_sections(log), reps=SYNTH_REPS)
        res_s1 = fit(read_sections(log), reps=SYNTH_REPS, wait_shape="sitting1")
        # the same log as sitting 1's bench printed it: no RH39/AH39 rows or histograms
        s1log = Path(tmp) / "S1.TXT"
        s1log.write_bytes("".join(
            ln for ln in synth_log(marks=marks, stale_after=68).splitlines(keepends=True)
            if not ln.startswith(("RH39", "AH39", "#HIST RH39", "#HIST AH39"))).encode("ascii"))
        res_s1inf = fit(read_sections(s1log), reps=SYNTH_REPS)
        text_s1inf = report(res_s1inf)
        b9 = Path(tmp) / "BIN9.TXT"
        b9.write_bytes(synth_log(P=dict(SYNTH, stall_bin={63: 9})).encode("ascii"))
        res_b9 = fit(read_sections(b9), reps=SYNTH_REPS)
        bad = Path(tmp) / "BAD.TXT"
        bad.write_bytes(synth_log(distort=(62, "ARSW", 1.03)).encode("ascii"))
        res_bad = fit(read_sections(bad), reps=SYNTH_REPS)
        shortlog = Path(tmp) / "SHORT.TXT"
        shortlog.write_bytes(synth_log(short=(65, "RCOL")).encode("ascii"))
        res_short = fit(read_sections(shortlog), reps=SYNTH_REPS)
        runlog = Path(tmp) / "RUN.TXT"
        runlog.write_bytes(synth_log(short=(66, "RSEC", "NXB RUN")).encode("ascii"))
        res_run = fit(read_sections(runlog), reps=SYNTH_REPS)
        padlog = Path(tmp) / "PAD.TXT"
        padlog.write_bytes(synth_log(P=dict(SYNTH, pad_t=5.0)).encode("ascii"))
        res_pad = fit(read_sections(padlog), reps=SYNTH_REPS)
        text_pad = report(res_pad)
        no89 = Path(tmp) / "NO89.TXT"
        no89.write_bytes(synth_log(omit=(89,)).encode("ascii"))
        res_no89 = fit(read_sections(no89), reps=SYNTH_REPS)
        text_no89 = report(res_no89)
        padst = Path(tmp) / "PADST.TXT"
        padst.write_bytes(synth_log(P=dict(SYNTH, pad_t={"stereo": 5.0})).encode("ascii"))
        res_padst = fit(read_sections(padst), reps=SYNTH_REPS)
        undet = Path(tmp) / "UNDET.TXT"
        undet.write_bytes(synth_log(omit=(70, 71, 88)).encode("ascii"))
        res_undet = fit(read_sections(undet), reps=SYNTH_REPS)
        text_undet = report(res_undet)
        undet2 = Path(tmp) / "UNDET2.TXT"
        undet2.write_bytes(synth_log(omit=(70, 71, 88, 89)).encode("ascii"))
        res_undet2 = fit(read_sections(undet2), reps=SYNTH_REPS)
        # A fixture clip on disk: 066's layout, palette sectors on frames 0 and 20.
        g = geometry(256, 192, 25, 1)
        clipdir = Path(tmp) / "clips"
        clipdir.mkdir()
        hdr = nxv2enc.pack_header(width=256, height=192, fps=25, channels=1, arate=15625,
                                  frame_count=250, audio_bytes_per_frame=g.real,
                                  ring_start_margin_blocks=g.spix + 1,
                                  per_frame_cap_blocks=g.spix + 1,
                                  flags=0x13, raw_width=256)
        body = b"".join(nxv2enc.emit_raw_frame(bytes(g.real), g.padded, bytes(256 * 192),
                                               bytes(512) if i in (0, 20) else None)
                        for i in range(34))
        (clipdir / "066.VID").write_bytes(hdr + body)
        file_ok = check_clip_file(clipdir / "066.VID", 66)
        res_files = fit(read_sections(log), reps=SYNTH_REPS, clips_dir=clipdir)
        (clipdir / "066.VID").write_bytes(hdr[:9] + b"\x02" + hdr[10:] + body)
        file_bad = check_clip_file(clipdir / "066.VID", 66)
        swaplog = Path(tmp) / "SWAP.TXT"
        swaplog.write_bytes(synth_log(swap=66).encode("ascii"))
        res_swap = fit(read_sections(swaplog), reps=SYNTH_REPS)
        pb = Path(tmp) / "playback.md"
        pb.write_text("# t\n\n| Step | What |\n|---|---|\n| B.4 | 060 |\n\n"
                      "| Step | Clip | FRM | PLAY | LATE | URUN |\n|---|---|---|---|---|---|\n"
                      "| B.4 | 060 | 00FA/00FA | 01EE | 0000 | 0000 |\n"
                      "| B.18 | 074 | - | - | - | - |\n\n| Step | Clip | PLAY |\n"
                      "| X | 061 | 01EE |\n", encoding="utf-8")
        readouts = read_playback(pb)
        text = report(res, readouts)
        text_s1 = report(res_s1, readouts)
        text_b0 = report(replace(res, stall=0.0, stall_top=(0, 63)))
        pb2 = Path(tmp) / "playback2.md"
        pb2.write_text("| Step | Clip | FRM | PLAY | LATE | URUN |\n|---|---|---|---|---|---|\n"
                       "| 1 | 060 | 00FA/00FA | 01EE | 0000 | 0000 |\n"
                       "| 2 | 061 | 00FA/00FA | 01EE | - | - |\n"
                       "| 3 | 062 | 0001/0001 | 0002 | 0000 | 0000 |\n"
                       "| 4 | 063 | 0000/00FA | 021D | 00F9 | 00F9 |\n", encoding="utf-8")
        try:
            text_pb2 = report(res, read_playback(pb2))
        except ValueError as exc:
            text_pb2 = "report raised %r" % exc
    check([r["Clip"] for r in readouts] == ["060"], "playback rows: %r" % readouts)
    # a capture with no LATE/URUN row, and one that ended at once, are listed, never scored
    rows_pb2 = [ln for ln in text_pb2.splitlines() if ln.startswith("| ")]
    check(any(ln.startswith("| 1 | 060 |") for ln in rows_pb2)
          and not any(ln.startswith(("| 2 | 061 |", "| 3 | 062 |")) for ln in rows_pb2)
          and "not scored: 2 061 - no LATE, URUN or FRM figure" in text_pb2
          and "not scored: 3 062 - ended at once (FRM 0001/0001); LATE 0000 URUN 0000" in text_pb2,
          "cut and at-once captures are not scored: %s" % text_pb2[-400:])
    # at once needs both FRM halves 1 or less: 0000/00FA ran (a counter fault), so it is scored
    check(any(ln.startswith("| 4 | 063 |") and "| 00F9 | 00F9 | no |" in ln for ln in rows_pb2)
          and any(ln.startswith("| 4 | 063 | stereo | 250 |") for ln in rows_pb2)
          and "not scored: 4" not in text_pb2
          and not re.search(r"not scored: 2 061 [^\n]*; LATE", text_pb2),
          "FRM 0000/00FA is scored, frames from the nonzero half: %s" % text_pb2[-600:])
    # the wait shape from the log: RH39/AH39 rows or histograms only on the inline bench
    ns = SimpleNamespace
    check(infer_wait_shape([ns(rows={"RHST": 0}, hist={"AHST": []})]) == "sitting1"
          and infer_wait_shape([ns(rows={}, hist={}), ns(rows={}, hist={"AH39": []})]) == "inline"
          and infer_wait_shape([ns(rows={"RH39": 0}, hist={})]) == "inline",
          "infer_wait_shape")
    check(res_inf.wait_shape == "inline" and res_inf.stall == res.stall,
          "a log with RH39/AH39 rows is priced inline: %s" % res_inf.wait_shape)
    check(res_s1inf.wait_shape == "sitting1" and res_s1inf.stall == res_s1.stall
          and res_s1inf.anomalies == [] and "RH39" not in text_s1inf,
          "a log with no RH39/AH39 rows is sitting 1's, none expected: %s %r" % (
              res_s1inf.wait_shape, res_s1inf.anomalies))
    # the 39 T comparison: printed beside RHST/AHST, in no constant
    check(set(res.cmp39) == {"RH39", "AH39 stereo", "AH39 mono"}
          and all(abs(a - 1.0) < 1e-9 and abs(b - 1.0) < 1e-9 for a, b, _ in
                  [res.cmp39["RH39"]])
          and "First poll at the benched image's production spacing" in text
          and "First poll 18 T" not in text
          and "| RH39 | 1 |" in text and "| AH39 mono | 1 |" in text,
          "RH39/AH39 bins and the comparison line: %r" % res.cmp39)
    # DEBUG pixel sector work by wait shape: the token counter only in sitting 1's
    g320 = geometry(320, 192, 25, 2)
    rl = DBG["rl_poll"] / inc_equ("VID_RL_DIV")
    d_in, d_s1 = debug_work(res, g320, "stereo"), debug_work(res_s1, g320, "stereo")
    check(abs(d_in.pix - (86 + rl)) < 1e-9 and abs(d_s1.pix - (86 + 177 + rl)) < 1e-9
          and d_in.snd == d_s1.snd == 40 + 177 + rl and d_s1.total > d_in.total,
          "debug_work pixel sector: inline %.1f, sitting1 %.1f" % (d_in.pix, d_s1.pix))
    check("- per pixel sector %.1f T: vr_sector_n's PLAY divider 86 T" % (86 + rl) in text
          and "so it is not priced (wait shape inline)" in text
          and "- per pixel sector %.1f T" % (86 + 177 + rl) in text_s1
          and "poll counter 177 T (.got" in text_s1, "the DEBUG pixel sector line by shape")
    check("upper edge 0 T (the token on poll 1)" in text_b0 and "x -1" not in text_b0,
          "the bin 0 stall edge text")
    check("admitted clips that showed LATE or URUN: none" in text, "Step 6 lines printed")
    check(exit_status(res) == 0 and exit_status(res_short) == 1,
          "a RE-RUN anomaly makes the exit status 1")
    check(any("066" in a and "channel label" in a for a in res_swap.anomalies),
          "a twin with the other form's handler is listed: %r" % res_swap.anomalies)
    # ring_play: under rate, no waits and the sound sets the time; the 062 leg B case.
    tot, waits = ring_play(250, 0.9 * 1120000, 0.9 * 1120000, 1250, 2, per, 8192, 16, 256)
    check(waits == 0 and tot == 250 * 625 * per, "ring_play under rate: %r" % ((tot, waits),))
    tot, waits = ring_play(250, 1183393.0, 1212165.0, 1250, 2, per, 8192, 16, 256)
    check(waits == 3 and abs(tot / FIELD_T - 527.4) < 0.05,
          "ring_play 062 case: 3 waits, PLAY 527.4 (%r)" % ((tot / FIELD_T, waits),))
    tot, waits = ring_play(10, 0.5 * 1120000, 3 * 1120000, 1250, 2, per, 8192, 16, 256)
    check((tot, waits) == (12 * 625 * per, 0),
          "ring_play drops a deficit over a whole frame (.paced): %r" % ((tot, waits),))
    u = utilisation(res, 256, 192, 25, "stereo")
    check(u.period == 625 * per and u.ref_period == PERIOD_NUM / 25,
          "utilisation period: samples x CTC period (%r)" % u.period)
    h, u = largest_height(res, 320, 25, "stereo")
    check(u is not None and u <= 1.0 and (h == 256 or utilisation(
        res, 320, h + 1, 25, "stereo").util > 1.0), "largest_height: %r" % ((h, u),))
    check(file_ok == ([], [0, 20], []), "clip file walk: %r" % (file_ok,))
    check(any(b.startswith("channels 2 != 1") for b in file_bad[0]),
          "clip file header byte 9 checked: %r" % (file_bad[0],))
    check([a for a in res_files.anomalies if "066" in a and "[20]" in a] != [],
          "a palette sector inside RSWP/ARSW is an anomaly: %r" % res_files.anomalies)
    check(res_files.clipfiles[60] is None and res_files.clipfiles[66] is not None,
          "absent clip files are listed, present ones walked")
    check(any("row RCOL missing" in a for a in res_short.anomalies)
          and any("NXB SHORT" in a for a in res_short.anomalies),
          "NXB SHORT row is listed as missing and as a marker: %r" % res_short.anomalies)
    check(any("066" in a and "RSEC NXB RUN" in a and "fragmented" in a for a in res_run.anomalies)
          and any("row RSEC missing" in a for a in res_run.anomalies)
          and not any("fragmented" in a for a in res_short.anomalies)
          and any("NXB_RW_MIN" in a for a in res_short.anomalies) and exit_status(res_run) == 1,
          "NXB RUN names the fragmented file, NXB SHORT the clip length: %r" % res_run.anomalies)
    check(_near(res_short.k["stereo"]["tc"], SYNTH["k"]["stereo"]["tc"]),
          "fit still runs around a missing RCOL")
    P = SYNTH
    check(_near(res.ts, P["ts"]), "ts %.3f vs %.3f" % (res.ts, P["ts"]))
    for form in FORMS:
        for key, want in P["k"][form].items():
            got = res.k[form][key]
            check(_near(got, want), "%s %s %.4f vs %.4f" % (form, key, got, want))
        check(res.k[form]["ts"] == res.ts, "%s ts is RAW_SECTOR_T" % form)
        hc = res.handler[form]
        check(_near(hc, P["handler"][form]), "%s handler %.3f vs %.3f" % (
            form, hc, P["handler"][form]))
    check(_near(res.handler["old"], P["old_handler"]), "old handler %.3f" % res.handler["old"])
    rsec = SECTOR_INI_T + P["ts"] + H_CARD
    arse = (P["ts"] + 512 * P["k"]["stereo"]["tb"]) * rsec / (rsec - H_CARD)
    # bin to T by wait shape: inline 22 + 47 (n - 1), sitting 1 48 n; bin 3's upper edge 7
    check([_wait_t("inline", n) for n in (0, 1, 3, 7)] == [0, 22, 116, 304]
          and [_wait_t("sitting1", n) for n in (0, 1, 3, 7)] == [0, 48, 144, 336],
          "wait T by shape")
    for shape, r in (("inline", res), ("sitting1", res_s1)):
        p1 = WAIT_SHAPES[shape][0]
        want_stall = _wait_t(shape, 2 ** 3 - 1) * arse / rsec
        check(_near(r.stall, want_stall), "%s RAW_STALL_T %.3f vs %.3f" % (shape, r.stall,
                                                                           want_stall))
        check(_near(r.wait["unarmed"], p1), "%s unarmed mean wait %.3f vs %d (bin 1 only)" % (
            shape, r.wait["unarmed"], p1))
    check("22 + 47 x (n - 1)" in text and "a poll is 48 T" in text_s1,
          "the histogram header gives the shape")
    check(any("063" in a and "bin 9" in a for a in res_b9.anomalies) and exit_status(res_b9) == 1,
          "a wait in bin 9 is a RE-RUN anomaly: %r" % res_b9.anomalies)
    check(_near(res.col_unarmed, P["tc_unarmed"]), "unarmed column end %.3f" % res.col_unarmed)
    check(res.period == per, "CTC period %d" % res.period)
    check([(s.clip, s.failure) for s in res.excluded] == [(59, "VID FILE?")],
          "stale section excluded: %r" % [(s.clip, s.failure) for s in res.excluded])
    check(sorted(res.walked) == [(61, "ARSW"), (64, "ARSE")],
          "walk-marked rows excluded: %r" % sorted(res.walked))
    check(61 not in [r.clip for r in res.residuals], "a marked ARSW drops the clip's residual")
    check(res.accepted, "acceptance on the clean synthetic log: max %.4f" % res.max_resid)
    check(res.max_resid < 0.01, "residuals near 0: %.4f" % res.max_resid)
    check(not res_bad.accepted, "acceptance fails on a 3 percent ARSW distortion")
    worst = max(res_bad.residuals, key=lambda r: abs(r.pct))
    check(worst.clip == 62, "the distorted clip has the largest residual (%d)" % worst.clip)
    check(res.anomalies == [], "no anomalies on the synthetic log: %r" % res.anomalies)
    # 088 and 089 in the fit: each form's d determined, near 0 on a one-term log, rule PASS
    lsq_clips = {f: sorted(c for c, _, _ in res.lsq[f]) for f in FORMS}
    check(88 in lsq_clips["mono"] and 89 in lsq_clips["stereo"]
          and {s for c, s, _ in res.lsq["stereo"]} == {3, 4, 5}
          and {s for c, s, _ in res.lsq["mono"]} == {2, 3}, "fit sets: %r" % lsq_clips)
    check(res.pad["use"] == {"stereo": "stereo", "mono": "mono"}
          and all(abs(res.pad[f]["d"]) < 0.05 for f in FORMS) and res.sound_ok
          and "sound-term rule" in text and ": PASS (largest |d|" in text,
          "one-term log: d %r, rule %r" % ([res.pad[f]["d"] for f in FORMS], res.sound_ok))
    # a pad byte 5 T dearer: d = -5 in both forms, the rule fails and so does the exit status
    check(all(abs(res_pad.pad[f]["d"] + 5.0) < 0.05 for f in FORMS) and not res_pad.sound_ok
          and exit_status(res_pad) == 1 and ": FAIL (largest |d| 5.0" in text_pad,
          "pad surcharge: d %r, rule %r" % ([res_pad.pad[f]["d"] for f in FORMS],
                                            res_pad.sound_ok))
    # no 089: stereo bytes track Ssnd, so the rule takes the scaled stereo fit
    check(not res_no89.pad["stereo"]["determined"] and res_no89.pad["mono"]["determined"]
          and res_no89.pad["use"]["stereo"] == "stereo_d"
          and "stereo: d scaled from mono" in text_no89
          and "d not determined: the clips' sound bytes, 1250, 1874, 2500, track Ssnd"
          in text_no89, "stereo fallback without 089: %r" % res_no89.pad["use"])
    # a stereo-only pad surcharge: |d| is taken from both forms
    check(abs(res_padst.pad["stereo"]["d"] + 5.0) < 0.05 and abs(res_padst.pad["mono"]["d"]) < 0.05
          and abs(res_padst.sound[2] - 5.0) < 0.05 and not res_padst.sound_ok,
          "stereo-only pad surcharge: d %r, largest |d| %.2f, rule %r" % (
              [res_padst.pad[f]["d"] for f in FORMS], res_padst.sound[2], res_padst.sound_ok))
    # d = 0 but the gate 0.3 percent of a 25 fps period off the fit: the error clause fails it
    pa_off = dict(res.pad, mono=dict(res.pad["mono"], A=res.pad["mono"]["A"] + 0.003 * 625 * per))
    off = sound_rule(res, pa_off)
    check(not off[0] and off[2] < 0.05 and off[3] > SOUND_ERR_PCT,
          "gate off the fit with d = 0: ok %r, |d| %.3f, err %.3f" % (off[0], off[2], off[3]))
    # mono d not determined (070, 071, 088 out): a distinct verdict, failing closed
    check(res_undet.pad["use"] == {"stereo": "stereo", "mono": None}
          and res_undet.sound[4] == "NOT DETERMINED" and not res_undet.sound_ok
          and exit_status(res_undet) == 1
          and ": NOT DETERMINED (mono d: its sound bytes track Ssnd)" in text_undet
          and res_undet2.pad["use"] == {"stereo": None, "mono": None}
          and res_undet2.sound[4] == "NOT DETERMINED" and not res_undet2.sound_ok
          and res.sound[4] == "PASS" and res_pad.sound[4] == "FAIL",
          "undetermined d: use %r / %r, verdicts %r %r" % (
              res_undet.pad["use"], res_undet2.pad["use"], res_undet.sound[4:],
              res_undet2.sound[4:]))
    # undetermined mono: byte counts in numeric order, no scaled stereo figure printed
    check("d not determined: the clips' sound bytes, 625, 1024, track Ssnd" in text_undet
          and "stereo with d = mono d x armed ratio: not formed (mono d not determined)"
          in text_undet and "armed ratio = " not in text_undet and "armed ratio = " in text,
          "undetermined mono text: %r" % [ln for ln in text_undet.splitlines()
                                          if "not determined" in ln or "armed ratio" in ln])
    # --model: 1c this tree's frame harness (nxb_rw_feed reads through vid_raw_rdv's jp),
    # 1b sitting 1b's; a log made under 1b's harness is recovered under 1b, not under 1c
    check(MODEL_G_FRAME == {"1c": 220, "1b": 210} and G_FRAME == MODEL_G_FRAME["1c"]
          and MODEL_G_FRAME["1c"] == benchrows.RW_FRAME_HARNESS_T,
          "model frame harness %r, in force %d" % (MODEL_G_FRAME, G_FRAME))
    with tempfile.TemporaryDirectory() as tmp:
        log1b = Path(tmp) / "M1B.TXT"
        set_model("1b")
        try:
            log1b.write_bytes(synth_log().encode("ascii"))
            res_1b = fit(read_sections(log1b), reps=SYNTH_REPS, wait_shape="inline")
        finally:
            set_model("1c")
        res_1c = fit(read_sections(log1b), reps=SYNTH_REPS, wait_shape="inline")
    check(all(_near(res_1b.k[f][key], want) for f in FORMS
              for key, want in SYNTH["k"][f].items()),
          "a log under 1b's harness, --model 1b: constants recovered")
    check(abs(res_1c.k["mono"]["tf"] - res_1b.k["mono"]["tf"]) > 5,
          "the same log under 1c: tf moves (%.1f against %.1f)" % (
              res_1c.k["mono"]["tf"], res_1b.k["mono"]["tf"]))
    for f in fails:
        print("selftest FAIL: " + f)
    print("selftest: %s (%d checks, %d failed)" % ("PASS" if not fails else "FAIL", checks,
                                                  len(fails)))
    return 0 if not fails else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("log", nargs="?")
    ap.add_argument("--clips", help="folder holding the NNN.VID fixtures (read only)")
    ap.add_argument("--nr11", type=int, default=0, help="NR $11 of the sitting (default 0)")
    ap.add_argument("--playback", help="playback.md with the leg B readout table")
    ap.add_argument("--wait-shape", choices=sorted(WAIT_SHAPES), default=None,
                    help="override the token wait shape read from the log: inline (first 22, "
                         "then 47 T a poll) or sitting1 (48 each, the sitting-1 bench)")
    ap.add_argument("--model", choices=sorted(MODEL_G_FRAME), default="1c",
                    help="the bench image the log came from: 1c (this tree, the default) or "
                         "1b (sitting 1b's committed logs: frame harness %d T)" %
                         MODEL_G_FRAME["1b"])
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if not a.log:
        ap.error("a log path or --selftest")
    set_model(a.model)
    try:
        res = fit(read_sections(a.log), nr11=a.nr11, clips_dir=a.clips and Path(a.clips),
                  wait_shape=a.wait_shape)
        readouts = read_playback(a.playback) if a.playback else None
    except (nxbparse.LogError, FitError) as e:
        sys.stderr.write("error: %s\n" % e)
        return 2
    res.log = Path(a.log).name
    sys.stderr.write("wait shape: %s (%s)\n" % (
        res.wait_shape, "--wait-shape" if a.wait_shape else
        "inferred: RH39/AH39 rows present" if res.wait_shape == "inline" else
        "inferred: no RH39/AH39 rows"))
    sys.stdout.write(report(res, readouts))
    return exit_status(res)


if __name__ == "__main__":
    sys.exit(main())
