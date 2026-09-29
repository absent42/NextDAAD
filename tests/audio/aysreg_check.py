# AYS stream register-loss check (headless, ZEsarUX, DEBUG build).
#
# Plays the -AysReg leg's generated streams and, after each event that
# writes or parks the AY chips, compares all three PSGs' chip readback
# (the DEBUG aud_dbg_snap mirror) against the stream's authored register
# states from tests\out\aysreg\aysreg_states.json. A sample passes when
# every register of every PSG equals one authored state; samples taken
# while an effect or beep owns PSG 3, or with no stream live, are
# skipped.
#
# Run from the repo root, after
#     .\build.ps1                        (DEBUG - the mirror is DEBUG-only)
#     pwsh -File tests\build-tests.ps1 -AysReg
#     python tests/audio/aysreg_check.py --out <workdir>
#
# Exit 0 = every check passed, 1 = any check failed.
#
# EMULATOR-MODEL CAVEAT: chip readback is ZEsarUX's AY model, and video
# is not exercised here at all. A pass is register-state evidence only;
# the silicon sheet settles what is heard.

import argparse
import json
import os
import shutil
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "parser"))
import stopm_dump as sd   # noqa: E402  (Zrcp client, launch, connect)
import zrcp               # noqa: E402  (breakpoint counter)

ROOT = sd.ROOT
LEG = os.path.join(ROOT, "sd", "AYSREG")
STATES = os.path.join(ROOT, "tests", "out", "aysreg", "aysreg_states.json")

OFF_AUDFLAGS = 0x05
OFF_AYSFLAGS = 0x08
# AY register read-back widths (R0..R13)
MASK = [0xFF, 0x0F, 0xFF, 0x0F, 0xFF, 0x0F, 0x1F, 0xFF,
        0x1F, 0x1F, 0x1F, 0xFF, 0xFF, 0x0F]


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


MAP = os.path.join(ROOT, "build", "nextdaad.map")


def symbol(name, mapf):
    """Address of `name` in the image-under-test's map."""
    for line in open(mapf):
        p = line.split()
        if len(p) == 4 and p[3] == name:
            return int(p[0], 16)
    raise KeyError(name)


def chips(d):
    return [list(d[sd.OFF_AY + 14 * p: sd.OFF_AY + 14 * p + 14]) for p in range(3)]


def diffs(chip, state):
    out = []
    for p in range(3):
        for r in range(14):
            if (chip[p][r] ^ state[p][r]) & MASK[r]:
                out.append("PSG%d R%d=%02X want %02X" % (p + 1, r, chip[p][r], state[p][r]))
    return out


def live(d):
    return (d[OFF_AYSFLAGS] & 1) and not (d[OFF_AUDFLAGS] & 0x0C)


def check(z, states, seconds, label, log):
    """Sample for `seconds`; every live sample must match one state."""
    good = bad = 0
    first_bad = None
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        d = z.read(sd.SNAP, sd.SNAP_LEN)
        if not sd.intact(d) or not live(d):
            continue
        c = chips(d)
        best = min((diffs(c, s) for s in states.values()), key=len)
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
    return ok


def verb(z, text, wait=1.0):
    z.keys(text)
    z.enter(wait=wait)


BEEP_PERIOD = 424   # BEEP tone 120: audPeriods[(120-24)/2]


def effect(z, zc, log):
    """Fire ZAP and return True if PLY_AKY_PLAY ran. The effect is ~5
    frames, shorter than ZRCP's Enter hold, so its audFlags bit is never
    sampled; a breakpoint hit counter (var0) proves it played."""
    before = int(zc.evaluate("var0").strip() or 0)
    verb(z, "ZAP", wait=1.0)
    hits = int(zc.evaluate("var0").strip() or 0) - before
    log.append("      ZAP: PLY_AKY_PLAY ran %d tick(s)" % hits)
    time.sleep(0.5)
    return hits > 0


def event(z, text, bit, log):
    """Fire a PSG 3 event and return True once its audFlags bit has been
    seen set and then clear. For the beep, also check PSG 3 tone A."""
    verb(z, text, wait=0.05)
    try:
        d = sd.wait_for(z, lambda q: bool(q[OFF_AUDFLAGS] & bit), 5, text)
    except TimeoutError:
        log.append("      %s: active state never observed" % text)
        return False
    if bit == 0x08:
        r = chips(d)[2]
        per = r[0] | (r[1] & 0x0F) << 8
        log.append("      %s: PSG3 tone A period %d (want %d)" % (text, per, BEEP_PERIOD))
        if per != BEEP_PERIOD:
            return False
    wait_bit(z, OFF_AUDFLAGS, bit, False, 10)
    time.sleep(0.5)
    return True


def wait_bit(z, off, mask, want, seconds):
    try:
        sd.wait_for(z, lambda d: bool(d[off] & mask) == want, seconds, "flag")
        return True
    except TimeoutError:
        return False


def start(z, v):
    verb(z, v)
    if not wait_bit(z, OFF_AYSFLAGS, 1, True, 20):
        raise RuntimeError("%s: stream never went live" % v)
    time.sleep(1.0)


def run(sdir, port, states, mapf, log):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=1).close()
        raise RuntimeError("port %d already has a listener - a stale ZEsarUX?" % port)
    except OSError:
        pass
    proc = sd.launch(sdir, port)
    try:
        z = sd.connect(proc, port)
        z.cmd("smartload %s" % os.path.join(sdir, "nextdaad.nex"), wait=1.0, deadline=60)
        time.sleep(6.0)
        steady = states["steady"]
        results = []

        start(z, "STEADY")
        results.append(check(z, steady, 3.0, "baseline (no event)", log))

        zc = zrcp.Zrcp(port=port)
        zc.enter_cpu_step()
        zc.enable_breakpoints()
        zc.set_breakpoint(5, zrcp.pc_breakpoint_condition(symbol("PLY_AKY_PLAY", mapf)))
        zc.set_breakpoint_action(5, "let var0=var0+1")
        zc.exit_cpu_step()
        fired = effect(z, zc, log)
        results.append(check(z, steady, 3.0, "after AY effect", log) and fired)

        start(z, "STEADY")
        fired = event(z, "BLEEP", 0x08, log)
        results.append(check(z, steady, 3.0, "after BEEP", log) and fired)

        start(z, "STEADY")
        verb(z, "STOPFX")
        time.sleep(0.5)
        results.append(check(z, steady, 3.0, "after effect stop", log))

        start(z, "WRAP")
        results.append(check(z, states["wrap"], 12.0, "across loop wraps", log))
        return all(results)
    finally:
        try:
            proc.terminate()
        except Exception:
            pass
        proc.wait(timeout=20)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--port", type=int, default=10078)
    ap.add_argument("--nex", default=sd.NEX,
                    help="DEBUG image to test (default build\\nextdaad.nex)")
    ap.add_argument("--map", default=MAP,
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
