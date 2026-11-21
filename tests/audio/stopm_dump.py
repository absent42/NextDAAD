r"""STOPM three-point AY/player state dump on CSpect (tests\cspect), DEBUG build.

Boots the -AudLad leg, plays boot autoplay -> STOPM -> MUSIC restart and dumps the
aud_dbg_snap mirror (src\audio\audiobank.asm, AUD_STAGE0 $4000) at each point; a fresh
boot with no STOPM is the control. --ladder instead checks that each ladder rung drives
the channels it claims.

Run from the repo root, after
    .\build.ps1                            (DEBUG - the mirror is DEBUG-only)
    pwsh -File tests\build-tests.ps1 -AudLad

    python tests/audio/stopm_dump.py --out <workdir> [--restart LADR|LAD1] [--ladder] [--port N]

--port is the harness MCP port (tests\cspect\launcher.py PORT_RANGE, default the first free).

Sampling: the CPU stops at every aud_dbg_snap entry (run_to), where the mirror holds the
previous frame whole, so each frame is read once and none is torn. Boot starts paused, so
the first live frame is seen; POINT 2 and 3 are the first frames stepped after type_text
returns (a CSpect key press does not advance while the CPU stops every frame, so ENTER's
hold and gap run unstepped). Samples are keyed by song phase (linker position, frames
left in the pattern) and the runs are compared at the phases they share, collected from
each run's first live frame. GAME.AKY is a copy of 006.AKY, so LADR replays the
autoplay's bytes; LAD1 is another tune (same-player-state control only).

Chip readback: after each point PSG 1-3 R0-R13 are read with Session.ay_regs at the
aud_dbg_snap entry and compared with the mirror that frame then takes.

Everything here is CSpect's AY model, not silicon: emulator evidence, not a fidelity verdict."""

import argparse
import os
import shutil
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tests"))
sys.path.insert(0, os.path.join(ROOT, "tests", "xbn"))
from cspect import Session  # noqa: E402
import xbnrun  # noqa: E402  (wait_ready, submit)

NEX = os.path.join(ROOT, "build", "nextdaad.nex")
MAP = os.path.join(ROOT, "build", "nextdaad.map")
SD = os.path.join(ROOT, "sd")

FPS = 50                        # the old wall-clock windows, as frames
COLLECT_FRAMES = 25 * FPS       # collection window per scenario
SNAP_LABEL = "AUD_DBG_SNAP"     # read_map resolves the label, not its $4000 EQU twin
STEP_TIMEOUT_S = 10.0           # host deadline for one frame step
FRAME_TIMEOUT_S = 30.0
SNAP = 0x4000
OFF_SEQ = 0x04
OFF_AY = 0x10
OFF_ARR = 0x3A
OFF_CELL = 0x7A
OFF_SEQ2 = OFF_CELL + 2 * 40    # trailing copy of the sequence byte
SNAP_LEN = OFF_SEQ2 + 1         # header + AY + arrays + 40 words + tear byte

CELL_NAMES = (
    ["patternFrameCounter", "linkerPos", "sfxTable", "sfxStream"]
    + ["ch%d.ptTrack" % (i + 1) for i in range(9)]
    + ["ch%d.ptBlock" % (i + 1) for i in range(9)]
    + ["ch%d.wait" % (i + 1) for i in range(9)]
    + ["ch%d.lineState" % (i + 1) for i in range(9)]
)


def stage(workdir, leg):
    sd = os.path.join(os.path.abspath(workdir), "sd")
    if os.path.isdir(sd):
        shutil.rmtree(sd)
    os.makedirs(sd)
    # Whatever build-tests.ps1 staged for this leg, verbatim: GAME.DDB, GAME.AKY, NNN.AKY.
    src_dir = os.path.join(SD, leg)
    for name in os.listdir(src_dir):
        src = os.path.join(src_dir, name)
        if os.path.isfile(src) and (name.upper().endswith(".AKY")
                                    or name.upper() == "GAME.DDB"):
            shutil.copyfile(src, os.path.join(sd, name))
    shutil.copyfile(NEX, os.path.join(sd, "nextdaad.nex"))
    return sd


def boot(card, port=None, nex=None, map_file=MAP):
    """A harness Session on card's nextdaad.nex (or nex), stopped at the NEX entry so the
    first frame step sees boot from its start."""
    return Session.boot(card, nex or os.path.join(card, "nextdaad.nex"), map_file,
                        paused=True, port=port)


def run_free(s):
    if not s.running():
        s.resume()


def settle(s, frames):
    """Run `frames` frames; the CPU is left running."""
    run_free(s)
    s.wait_frames(frames, FRAME_TIMEOUT_S)


def type_line(s, text):
    """Type text and ENTER at the ready input editor; returns once typed, CPU running."""
    run_free(s)
    xbnrun.wait_ready(s)
    s.type_text(text + "\n")


def next_frame(s):
    """The mirror at the next aud_dbg_snap entry (the previous frame's); CPU left stopped there."""
    snap = s.sym(SNAP_LABEL)
    pc = s.run_to(snap, STEP_TIMEOUT_S)
    if pc != snap:
        raise RuntimeError("stopped at $%04X, not at aud_dbg_snap $%04X" % (pc, snap))
    return s.read(SNAP, SNAP_LEN)


def intact(dump):
    """Signature present and both copies of the sequence byte agree."""
    return dump[0:4] == b"AYS1" and dump[OFF_SEQ] == dump[OFF_SEQ2]


def phase(dump):
    """The AKY player's song position: which linker entry it is on and
    how many frames are left in the current pattern."""
    counter = struct.unpack_from("<H", dump, OFF_CELL)[0]
    linker = struct.unpack_from("<H", dump, OFF_CELL + 2)[0]
    return (linker, counter)


def playing(dump):
    return bool(dump[0x05] & 1)


def collect(s, frames, seed=(), want_playing=True):
    """{phase: dump} over the next `frames` frames, seeded with dumps already taken."""
    out = {}

    def keep(d):
        if intact(d) and (playing(d) or not want_playing):
            out.setdefault(phase(d), d)
    for d in seed:
        keep(d)
    for _ in range(frames):
        keep(next_frame(s))
    return out


def wait_for(s, pred, frames, what):
    """The first intact mirror within `frames` frames satisfying pred; CPU left stopped there."""
    for _ in range(frames):
        d = next_frame(s)
        if intact(d) and pred(d):
            return d
    raise TimeoutError("timed out waiting for %s (%d frames)" % (what, frames))


def chip_readback(s):
    """(mirror, [R0-R13 x 3]): Session.ay_regs at this aud_dbg_snap stop, then the mirror
    that frame takes, which reads the same chip state."""
    snap = s.sym(SNAP_LABEL)
    if s.running() or s.regs()["PC"] != snap:
        raise RuntimeError("chip readback needs the CPU stopped at aud_dbg_snap $%04X" % snap)
    chips = [s.ay_regs(p) for p in range(3)]
    return next_frame(s), chips


def chip_mismatch(dump, chips):
    out = []
    for p in range(3):
        for r in range(14):
            m = dump[OFF_AY + 14 * p + r]
            if chips[p][r] != m:
                out.append("PSG%d R%d ay=%02X mirror=%02X" % (p + 1, r, chips[p][r], m))
    return out


def chip_text(dump, chips):
    bad = chip_mismatch(dump, chips)
    if not bad:
        return "  chip readback (ay_regs): equals the mirror on all 42 registers"
    return ("  chip readback (ay_regs): %d register(s) differ from the mirror - %s"
            % (len(bad), ", ".join(bad)))


def fmt_ay(dump):
    lines = []
    for p in range(3):
        r = dump[OFF_AY + 14 * p: OFF_AY + 14 * p + 14]
        tones = [r[2 * c] | ((r[2 * c + 1] & 0x0F) << 8) for c in range(3)]
        lines.append("  PSG%d  tone %-5d %-5d %-5d  vol %2d %2d %2d  "
                     "R6=%02X R7=%02X env=%04X R13=%02X"
                     % (p + 1, tones[0], tones[1], tones[2],
                        r[8] & 0x1F, r[9] & 0x1F, r[10] & 0x1F,
                        r[6], r[7], r[11] | (r[12] << 8), r[13]))
    return "\n".join(lines)


def fmt_cells(dump):
    lines = []
    for i, name in enumerate(CELL_NAMES):
        v = struct.unpack_from("<H", dump, OFF_CELL + 2 * i)[0]
        lines.append("  %-22s %04X" % (name, v))
    return "\n".join(lines)


def fmt_header(dump):
    return ("  audFlags=%02X songNum=%02X playerUp=%02X aysFlags=%02X "
            "smpFlags=%02X req=%02X req2=%02X beepFrames=%d enable=%02X loop=%02X"
            % (dump[0x05], dump[0x06], dump[0x07], dump[0x08], dump[0x09],
               dump[0x0A], dump[0x0B],
               struct.unpack_from("<H", dump, 0x0C)[0], dump[0x0E], dump[0x0F]))


def dump_text(title, d):
    return "\n".join([title, fmt_header(d), fmt_ay(d), fmt_cells(d)])


def diff(a, b):
    """Byte offsets where two same-phase dumps differ, minus the sequence
    byte, request mailbox, and song number - each differs by construction
    (audSongNum records which entry point loaded the song, not player
    state), not by fault."""
    skip = {OFF_SEQ, OFF_SEQ2, 0x0A, 0x0B, 0x06}
    out = []
    for i in range(SNAP_LEN):
        if i in skip:
            continue
        if a[i] != b[i]:
            out.append(i)
    return out


def describe(off):
    if off < OFF_AY:
        return "header+%02X" % off
    if off < OFF_ARR:
        n = off - OFF_AY
        return "PSG%d R%d (chip)" % (n // 14 + 1, n % 14)
    if off < OFF_CELL:
        n = off - OFF_ARR
        which = ["PSG1", "PSG2", "PSG3", "SFX"][n // 16]
        return "%s array +%d" % (which, n % 16)
    n = off - OFF_CELL
    return "%s %s" % (CELL_NAMES[n // 2], "lo" if n % 2 == 0 else "hi")


def run_scenario(sd, port, do_stopm, log, restart="LADR"):
    with boot(sd, port) as s:
        # aud_boot_probe loads GAME.AKY and files the start-music request
        d0 = wait_for(s, playing, 60 * FPS, "boot autoplay")
        log.append(dump_text("--- boot autoplay (first frame with music live)", d0))
        d1, chips = chip_readback(s)
        log.append(chip_text(d1, chips))
        if not do_stopm:
            return collect(s, COLLECT_FRAMES, (d0, d1)), log
        settle(s, 2 * FPS)                  # let the tune get past its first note
        xbnrun.wait_ready(s)
        pre = wait_for(s, playing, 10 * FPS, "a clean pre-STOPM sample")
        log.append(dump_text("--- POINT 1: pre-STOPM", pre))
        log.append(chip_text(*chip_readback(s)))
        type_line(s, "STOPM")
        post = wait_for(s, lambda d: not playing(d), 15 * FPS, "STOPM to take effect")
        log.append(dump_text("--- POINT 2: post-STOPM", post))
        log.append(chip_text(*chip_readback(s)))
        settle(s, FPS)
        post2 = wait_for(s, lambda d: not playing(d), 10 * FPS, "a clean post-STOPM sample")
        log.append(dump_text("--- POINT 2b: post-STOPM, one second later", post2))
        log.append(chip_text(*chip_readback(s)))
        type_line(s, restart)
        rst = wait_for(s, playing, 20 * FPS, "MUSIC restart")
        log.append(dump_text("--- POINT 3: post-restart MUSIC (first live frame)", rst))
        r1, chips = chip_readback(s)
        log.append(chip_text(r1, chips))
        log.append("restart transient phase = %04X:%04X" % phase(rst))
        return collect(s, COLLECT_FRAMES, (rst, r1)), log


LADDER = [("LAD1", 1), ("LAD3", 3), ("LAD6", 6), ("LAD9", 9), ("LADQ", 9),
          ("LADR", None)]


def sounding(dump, only_psg=None):
    """How many AY channels are actually making a noise: non-zero
    volume, tone bit open in R7, and a non-zero period."""
    live = 0
    for p in range(3):
        if only_psg is not None and p != only_psg:
            continue
        r = dump[OFF_AY + 14 * p: OFF_AY + 14 * p + 14]
        for c in range(3):
            tone = r[2 * c] | ((r[2 * c + 1] & 0x0F) << 8)
            if (r[8 + c] & 0x1F) and not (r[7] & (1 << c)) and tone:
                live += 1
    return live


def run_ladder(sd, port, log):
    """Per rung, whether it drives exactly the channels it claims with the intended
    periods and volumes - stimulus verification for the ear card, not a sound verdict."""
    with boot(sd, port) as s:
        wait_for(s, playing, 60 * FPS, "boot autoplay")
        run_free(s)
        xbnrun.wait_ready(s)
        for verb, channels in LADDER:
            # aud_load_song stops the previous rung before it overwrites the song area
            run_free(s)
            xbnrun.submit(s, verb)
            d = wait_for(s, playing, 20 * FPS, verb)
            settle(s, 20)
            d = wait_for(s, playing, 5 * FPS, verb + " settled")
            live = sounding(d)
            if channels is None:
                # real material: report the peak and per-PSG reach over the window
                peak, psgs, best = 0, [False] * 3, d
                for _ in range(25 * FPS):
                    q = next_frame(s)
                    if not intact(q) or not playing(q):
                        continue
                    n = sounding(q)
                    if n > peak:
                        peak, best = n, q
                    for pi in range(3):
                        if sounding(q, pi):
                            psgs[pi] = True
                log.append("--- rung %s: real material, %d channel(s) at "
                           "the first sample, PEAK %d over 25 s, PSGs "
                           "reached: %s" % (verb, live, peak,
                           ", ".join("PSG%d" % (i + 1)
                                     for i in range(3) if psgs[i]) or "none"))
                log.append(fmt_ay(best))
                log.append(chip_text(*chip_readback(s)))
                continue
            log.append("--- rung %s: %d channel(s) expected, %d sounding"
                       % (verb, channels, live))
            log.append(fmt_ay(d))
            if live != channels:
                log.append("  MISMATCH - the rung is not driving what it should")
            log.append(chip_text(*chip_readback(s)))
        return log


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--port", type=int, default=None,
                    help="harness MCP port (default the first free in PORT_RANGE)")
    ap.add_argument("--leg", default="AUDLAD",
                    help="leg subfolder under sd\\ staged by build-tests.ps1 "
                         "(default AUDLAD, written by -AudLad)")
    ap.add_argument("--restart", default="LADR",
                    help="verb that restarts the music after STOPM. "
                         "LADR (default) is the kit's real 9-channel tune "
                         "and is byte-identical to the boot autoplay; LAD1 "
                         "is the synthetic single-channel rung and is NOT")
    ap.add_argument("--ladder", action="store_true",
                    help="Task 7a: verify each ladder rung drives the "
                         "channels it claims, instead of the 7b STOPM dump")
    args = ap.parse_args()
    if not os.path.exists(NEX):
        sys.exit("build/nextdaad.nex missing - run .\\build.ps1 (DEBUG)")
    if not os.path.isfile(os.path.join(SD, args.leg, "GAME.DDB")):
        sys.exit("sd\\%s\\GAME.DDB missing - run tests\\build-tests.ps1 -AudLad" % args.leg)
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    sd = stage(out, args.leg)

    if args.ladder:
        log = ["=== LADDER RUNG VERIFICATION (emulator model, not a fidelity verdict) ==="]
        log = run_ladder(sd, args.port, log)
        text = "\n".join(log) + "\n"
        path = os.path.join(out, "ladder-check.txt")
        with open(path, "w") as f:
            f.write(text)
        print(text)
        print("written to %s" % path)
        return

    log = []
    log.append("=== CONTROL: fresh boot, autoplay only, no STOPM ===")
    ctrl, log = run_scenario(sd, args.port, False, log, args.restart)
    log.append("")
    log.append("=== REPRO: fresh boot, autoplay -> STOPM -> %s ===" % args.restart)
    repro, log = run_scenario(sd, args.port, True, log, args.restart)

    common = sorted(set(ctrl) & set(repro))
    log.append("")
    log.append("=== PHASE-MATCHED COMPARISON ===")
    log.append("control samples %d, repro samples %d, phases in common %d"
               % (len(ctrl), len(repro), len(common)))
    # the restart transient must be in the compared set, not just counted
    for line in log:
        if line.startswith("restart transient phase = "):
            tp = line.split("= ")[1].split(":")
            tph = (int(tp[0], 16), int(tp[1], 16))
            if tph in common:
                d = diff(ctrl[tph], repro[tph])
                log.append("restart transient phase %04X:%04X IS in the "
                           "compared set - %s" % (tph[0], tph[1],
                           "differs at %d offset(s)" % len(d) if d
                           else "identical to the control"))
            else:
                log.append("WARNING: restart transient phase %04X:%04X is "
                           "NOT in the compared set - the transient was "
                           "not covered, widen COLLECT_FRAMES" % tph)
            break
    if not common:
        log.append("NO COMMON PHASE - comparison impossible, widen the collect window")
    bad = 0
    seen = {}
    for ph in common:
        d = diff(ctrl[ph], repro[ph])
        if d:
            bad += 1
            for off in d:
                seen.setdefault(describe(off), 0)
                seen[describe(off)] += 1
    log.append("phases whose dumps differ: %d of %d" % (bad, len(common)))
    if seen:
        log.append("differing fields (field: how many phases):")
        for k in sorted(seen):
            log.append("  %-24s %d" % (k, seen[k]))
        ph = next(p for p in common if diff(ctrl[p], repro[p]))
        log.append("")
        log.append(dump_text("--- first differing phase %04X:%04X - CONTROL"
                             % (ph[0], ph[1]), ctrl[ph]))
        log.append(dump_text("--- first differing phase %04X:%04X - REPRO"
                             % (ph[0], ph[1]), repro[ph]))
    else:
        log.append("NO DIFFERENCE at any matched phase - post-restart state is "
                   "byte-identical to the fresh-boot control")

    text = "\n".join(log) + "\n"
    path = os.path.join(out, "stopm-dump.txt")
    with open(path, "w") as f:
        f.write(text)
    print(text)
    print("written to %s" % path)


if __name__ == "__main__":
    main()
