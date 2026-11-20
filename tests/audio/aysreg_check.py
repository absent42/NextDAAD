r"""AYS stream register-loss check on CSpect (tests\cspect), DEBUG build.

Plays the -AysReg leg's generated streams and, after each event that writes or parks the
AY chips, compares all three PSGs' chip readback (the aud_dbg_snap mirror) with the
stream's authored register states from tests\out\aysreg\aysreg_states.json. A sample
passes when every register of every PSG equals one authored state; samples taken while an
effect or beep owns PSG 3, or with no stream live, are skipped. At the end of each window
PSG 1-3 are also read with Session.ay_regs and compared with the mirror and the states.

Run from the repo root, after
    .\build.ps1                        (DEBUG - the mirror is DEBUG-only)
    pwsh -File tests\build-tests.ps1 -AysReg
    python tests/audio/aysreg_check.py --out <workdir> [--port N]

--port is the harness MCP port (tests\cspect\launcher.py PORT_RANGE, default the first free).
Every frame of a window is sampled once (stopm_dump.next_frame). Exit 0 = every check
passed, 1 = any check failed.

Chip readback is CSpect's AY model and video is not exercised: register-state evidence
only; the silicon sheet settles what is heard."""

import argparse
import json
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import stopm_dump as sd   # noqa: E402  (boot, frame stepping, chip readback)
import xbnrun             # noqa: E402  (wait_ready, submit; on the path via stopm_dump)

ROOT = sd.ROOT
LEG = os.path.join(ROOT, "sd", "AYSREG")
STATES = os.path.join(ROOT, "tests", "out", "aysreg", "aysreg_states.json")
FPS = sd.FPS

OFF_AUDFLAGS = 0x05
OFF_AYSFLAGS = 0x08
# AY register read-back widths (R0..R13)
MASK = [0xFF, 0x0F, 0xFF, 0x0F, 0xFF, 0x0F, 0x1F, 0xFF,
        0x1F, 0x1F, 0x1F, 0xFF, 0xFF, 0x0F]
EFFECT_FRAMES = 60              # ENTER, the response and the effect (old: ENTER held + 1 s)
EFFECT_DEADLINE_S = 60.0
POLL_S = 0.01
CALL_SCAN = 16                  # bytes from aud_tick.gate searched for its call nz, PLY_AKY_PLAY


def stage(workdir, nex):
    dst = os.path.join(os.path.abspath(workdir), "sd")
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.makedirs(dst)
    for name in os.listdir(LEG):
        src = os.path.join(LEG, name)
        if os.path.isfile(src):
            shutil.copyfile(src, os.path.join(dst, name))
    shutil.copyfile(nex, os.path.join(dst, "nextdaad.nex"))
    return dst


def chips(d):
    return [list(d[sd.OFF_AY + 14 * p: sd.OFF_AY + 14 * p + 14]) for p in range(3)]


def diffs(chip, state):
    out = []
    for p in range(3):
        for r in range(14):
            if (chip[p][r] ^ state[p][r]) & MASK[r]:
                out.append("PSG%d R%d=%02X want %02X" % (p + 1, r, chip[p][r], state[p][r]))
    return out


def closest(chip, states):
    return min((diffs(chip, s) for s in states.values()), key=len)


def live(d):
    return (d[OFF_AYSFLAGS] & 1) and not (d[OFF_AUDFLAGS] & 0x0C)


def chip_window(s, states, label, chip_log):
    """At the window's last aud_dbg_snap stop: ay_regs against the mirror of that frame
    and, when a stream is live, against the closest state."""
    d, ay = sd.chip_readback(s)
    vs_mirror = sd.chip_mismatch(d, ay)
    vs_state = closest([list(c) for c in ay], states) if live(d) else None
    chip_log.append((label, vs_mirror, vs_state))


def check(s, states, frames, label, log, chip_log):
    """Sample `frames` frames; every live sample must match one state."""
    good = bad = 0
    first_bad = None
    for _ in range(frames):
        d = sd.next_frame(s)
        if not sd.intact(d) or not live(d):
            continue
        best = closest(chips(d), states)
        if best:
            bad += 1
            if first_bad is None:
                first_bad = best
        else:
            good += 1
    ok = bad == 0 and good >= 10
    log.append("%s  %-28s %d matching, %d mismatching sample(s)"
               % ("PASS" if ok else "FAIL", label, good, bad))
    if first_bad:
        log.append("      first mismatch (vs closest state): " + ", ".join(first_bad))
    chip_window(s, states, label, chip_log)
    return ok


def chip_result(chip_log, log):
    """One line for the ay_regs reads taken at the end of every window."""
    n = len(chip_log)
    eq = sum(1 for _, m, _ in chip_log if not m)
    lives = [st for _, _, st in chip_log if st is not None]
    match = sum(1 for st in lives if not st)
    ok = eq == n and match == len(lives)
    log.append("%s  %-28s %d window end(s): %d equal the mirror, %d of %d live match a state"
               % ("PASS" if ok else "FAIL", "chip readback (ay_regs)", n, eq, match, len(lives)))
    for label, vs_mirror, vs_state in chip_log:
        if vs_mirror:
            log.append("      %s: ay_regs vs mirror: %s" % (label, ", ".join(vs_mirror)))
        if vs_state:
            log.append("      %s: ay_regs vs closest state: %s" % (label, ", ".join(vs_state)))
        if vs_state is None:
            log.append("      %s: no stream live at the window end, state not compared" % label)
    return ok


BEEP_PERIOD = 424   # BEEP tone 120: audPeriods[(120-24)/2]


def ply_call_site(s):
    """aud_tick's call nz, PLY_AKY_PLAY, found on the audio page: a stop at PLY_AKY_PLAY
    itself crashes CSpect 4.5.9.0 (IndexOutOfRangeException in its run loop)."""
    ply = s.sym("PLY_AKY_PLAY")
    gate, phys, _ = s.symbols["AUD_TICK@GATE"]
    code = s.read_page(phys >> 13, phys & 0x1FFF, CALL_SCAN)
    i = code.find(bytes((0xC4, ply & 0xFF, ply >> 8)))
    if i < 0:
        raise RuntimeError("no call nz, PLY_AKY_PLAY within %d bytes of aud_tick.gate" % CALL_SCAN)
    return gate + i


def queue_enter(s):
    """Queue ENTER with the CPU stopped (CSpect presses it once the CPU runs): a stop during
    a blocking press would stall it. Session.press refuses a stopped CPU, hence the direct call."""
    if s.running():
        raise RuntimeError("queue_enter needs the CPU stopped")
    t = s.mcp.text(s.mcp.call("press_keys", keys="ENTER"))
    if not t.startswith("Keys queued"):
        raise RuntimeError("press_keys with the CPU stopped: %r" % t[:200])


def effect(s, log):
    """Fire ZAP and return True if PLY_AKY_PLAY ran. The ~5-frame effect plays while ENTER
    is held, so a breakpoint on its call counts the calls taken (Z clear) over
    EFFECT_FRAMES frames from ENTER."""
    sd.run_free(s)
    xbnrun.wait_ready(s)
    site = ply_call_site(s)
    s.type_text("ZAP")
    s.pause()
    queue_enter(s)
    f0, hits = s.frame(), 0
    deadline = time.monotonic() + EFFECT_DEADLINE_S
    s.set_breakpoint(site)
    try:
        s.resume()
        while (s.frame() - f0) & 0xFFFF < EFFECT_FRAMES:
            pc = s.stopped_at()
            if pc is not None:
                if pc != site:
                    raise RuntimeError("stopped at $%04X, not at the PLY_AKY_PLAY call $%04X"
                                       % (pc, site))
                hits += not (s.regs()["F"] & 0x40)
                s.resume()
                continue
            if time.monotonic() >= deadline:
                raise TimeoutError("ZAP: %d frames not run in %g s"
                                   % (EFFECT_FRAMES, EFFECT_DEADLINE_S))
            time.sleep(POLL_S)
    finally:
        s.clear_breakpoint(site)
        sd.run_free(s)
    log.append("      ZAP: PLY_AKY_PLAY ran %d tick(s)" % hits)
    sd.settle(s, FPS // 2)
    return hits > 0


def event(s, text, bit, log):
    """Fire a PSG 3 event and return True once its audFlags bit has been
    seen set and then clear. For the beep, also check PSG 3 tone A."""
    sd.type_line(s, text)
    try:
        d = sd.wait_for(s, lambda q: bool(q[OFF_AUDFLAGS] & bit), 5 * FPS, text)
    except TimeoutError:
        log.append("      %s: active state never observed" % text)
        return False
    if bit == 0x08:
        r = chips(d)[2]
        per = r[0] | (r[1] & 0x0F) << 8
        log.append("      %s: PSG3 tone A period %d (want %d)" % (text, per, BEEP_PERIOD))
        if per != BEEP_PERIOD:
            return False
    wait_bit(s, OFF_AUDFLAGS, bit, False, 10 * FPS)
    sd.settle(s, FPS // 2)
    return True


def wait_bit(s, off, mask, want, frames):
    try:
        sd.wait_for(s, lambda d: bool(d[off] & mask) == want, frames, "flag")
        return True
    except TimeoutError:
        return False


def verb(s, text):
    """Submit a command line; returns once the input editor is ready again."""
    sd.run_free(s)
    xbnrun.submit(s, text)


def start(s, v):
    verb(s, v)
    if not wait_bit(s, OFF_AYSFLAGS, 1, True, 20 * FPS):
        raise RuntimeError("%s: stream never went live" % v)
    sd.settle(s, FPS)


def run(sdir, port, states, mapf, log):
    with sd.boot(sdir, port, map_file=mapf) as s:
        sd.run_free(s)
        xbnrun.wait_ready(s)
        steady = states["steady"]
        results, chip_log = [], []

        start(s, "STEADY")
        results.append(check(s, steady, 3 * FPS, "baseline (no event)", log, chip_log))

        fired = effect(s, log)
        results.append(check(s, steady, 3 * FPS, "after AY effect", log, chip_log) and fired)

        start(s, "STEADY")
        fired = event(s, "BLEEP", 0x08, log)
        results.append(check(s, steady, 3 * FPS, "after BEEP", log, chip_log) and fired)

        start(s, "STEADY")
        verb(s, "STOPFX")
        sd.settle(s, FPS // 2)
        results.append(check(s, steady, 3 * FPS, "after effect stop", log, chip_log))

        start(s, "WRAP")
        results.append(check(s, states["wrap"], 12 * FPS, "across loop wraps", log, chip_log))
        results.append(chip_result(chip_log, log))
        return all(results)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--port", type=int, default=None,
                    help="harness MCP port (default the first free in PORT_RANGE)")
    ap.add_argument("--nex", default=sd.NEX,
                    help="DEBUG image to test (default build\\nextdaad.nex)")
    ap.add_argument("--map", default=sd.MAP,
                    help="that image's symbol map (default build\\nextdaad.map)")
    a = ap.parse_args()
    with open(STATES) as fh:
        states = json.load(fh)
    sdir = stage(a.out, os.path.abspath(a.nex))
    log = []
    ok = run(sdir, a.port, states, os.path.abspath(a.map), log)
    text = "\n".join(log)
    print(text)
    with open(os.path.join(os.path.abspath(a.out), "aysreg_check.log"), "w") as fh:
        fh.write(text + "\n")
    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
