r"""Drives tests\cycle.dsf on CSpect (tests\cspect) and checks the DEBUG snapshot, the live
hook mask, the flags and the tick's scratch buffer after every step.

Run from the repo root, after
    .\build.ps1                            (DEBUG - the snapshot is DEBUG-only)
    pwsh -File tests\build-tests.ps1 -Cycle

    python tests\cycle_dump.py [--upto N] [--port N] [--work DIR] [-v]

--port is the harness MCP port (tests\cspect\launcher.py PORT_RANGE, default the first free).
Snapshot layout mirrors cyc_dbg_snap in src\sprites.asm: 16 bytes at CYC_DBG_SNAP ($5600).
cycScratch is read from page SPR_PAGE; the step counter must match before and after.
Each step waits for its own MESSAGE on the tilemap; settles count FRAMECOUNTER."""
import argparse
import pathlib
import shutil
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from cspect import Session                             # noqa: E402

LEG = ROOT / "sd" / "CYCLE"
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"

SNAP = 0x5600
SNAP_LEN = 16
HOOK_CYC = 4
SLOT7 = 0xE000                     # SPR_PAGE's CPU window under the hook
STORM_DONE = "S13 storm under a cycle"   # MESSAGE 12, printed after PROCESS 3-6
STORM_DEADLINE = 20.0              # the storm's length depends on the build
# Bare SYMBOL SHIFT: kb_char maps it to 0, wait_key takes any key (src\overlay1.asm, src\print.asm)
DISMISS_KEY = "SYM"
DISMISS_HOLD_FRAMES = 6
STEP_WAIT_S = 30.0                 # host deadline for a step's MESSAGE
STEPS_WAIT_S = 3.0                 # host deadline for the tick to reach a step count
FRAME_WAIT_S = 10.0
FROZEN_FRAMES = 25                 # a stopped cycle must not step for this long
POLL_S = 0.02


def identity_entry(i):
    """The palette card's identity palette: RRRGGGBB = i, second byte = the
    ninth blue bit, B1 OR B0 (mkpalcard.py), masked as the tick stores it."""
    return bytes((i & 0xFF, 1 if (i & 3) else 0))


def flag_rgb(index):
    """R, G, B as GFX f 10 writes them for identity entry `index`."""
    r = index & 0xE0
    g = ((index >> 2) & 7) << 5
    b = ((index & 3) << 6) | ((1 if (index & 3) else 0) << 5)
    return (r, g, b)


_spr_page = None


def spr_page(s):
    """SPR_PAGE from the map, confirmed by "CYC1" at msgCycSig's and "SPR1" at msgSprSig's
    in-page offsets."""
    global _spr_page
    if _spr_page is None:
        pg = s.sym("SPR_PAGE")
        sigs = (("MSGCYCSIG", b"CYC1"), ("MSGSPRSIG", b"SPR1"))
        got = {n: s.read_page(pg, s.sym(n) - SLOT7, 4) for n, _ in sigs}
        if any(got[n] != want for n, want in sigs):
            sys.exit("cycle_dump: page SPR_PAGE %d lacks CYC1/SPR1 at their offsets (%r)" % (pg, got))
        _spr_page = pg
    return _spr_page


class State:
    def __init__(self, s):
        for i in range(5):
            b = s.read(SNAP, SNAP_LEN)
            if b[:4] == b"CYC1" and b[4] == b[15]:
                break
            if i == 0 and b[:4] != b"CYC1":
                sys.exit("cycle_dump: no DEBUG snapshot at $%04X: build DEBUG "
                         "last (pwsh build.ps1) before staging, and the first "
                         "GFX 11 must have run" % SNAP)
            s.wait_frames(1, FRAME_WAIT_S)
        else:
            sys.exit("cycle_dump: snapshot torn at $%04X" % SNAP)
        self.seq = b[4]
        self.first, self.last, self.frames, self.count = b[6], b[7], b[8], b[9]
        self.steps = b[10] | (b[11] << 8)
        self.reason = b[12]
        # armed comes from the LIVE mask: a stop through gfx_drawtarget_clear
        # (RAMLOAD) takes no snapshot, so the snapshot's own byte can be stale.
        self.armed = s.read(s.sym("XBNINTON"), 1)[0] & HOOK_CYC

    def summary(self):
        return ("seq %d armed %d range %d-%d frames %d count %d steps %d reason %d"
                % (self.seq, self.armed, self.first, self.last, self.frames,
                   self.count, self.steps, self.reason))


def read_scratch(s, count):
    """count entries (2 bytes each) from cycScratch on SPR_PAGE, consistent across a step:
    the header's step counter must read the same before and after."""
    off = s.sym("CYCSCRATCH") - SLOT7
    for _ in range(20):
        before = State(s).steps
        data = s.read_page(spr_page(s), off, count * 2)
        after = State(s).steps
        if before == after:
            return data, after
        s.wait_frames(1, FRAME_WAIT_S)
    sys.exit("cycle_dump: cycScratch never held still across a read")


def read_flags(s, first, n):
    return tuple(s.read(s.sym("FLAGS") + first, n))


def expect(cond, what):
    if not cond:
        sys.exit("cycle_dump: FAIL " + what)


def wait_text(s, text, deadline):
    """Seconds until text is on the tilemap; fails after deadline seconds."""
    t0 = time.monotonic()
    try:
        s.wait_until(lambda: any(text in r for r in s.rows()), deadline, POLL_S, repr(text))
    except TimeoutError:
        sys.exit("cycle_dump: FAIL %r not on screen within %.0f s" % (text, deadline))
    return time.monotonic() - t0


def step(s, text):
    """Dismiss the ANYKEY, then the snapshot once the next step's MESSAGE is on screen."""
    s.press(DISMISS_KEY, frames=DISMISS_HOLD_FRAMES)
    wait_text(s, text, STEP_WAIT_S)
    return State(s)


def wait_steps(s, at_least, timeout=STEPS_WAIT_S):
    deadline = time.monotonic() + timeout
    while True:
        st = State(s)
        if st.steps >= at_least or time.monotonic() > deadline:
            return st
        time.sleep(POLL_S)


def boot(work, port):
    sd = pathlib.Path(work).resolve() / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    shutil.copytree(LEG, sd)
    shutil.copyfile(NEX, sd / "nextdaad.nex")
    return Session.boot(sd, sd / "nextdaad.nex", MAP, port=port)


def check_rotation(s, st, tag, base=0):
    """The scratch holds the range as the tick read it at its LAST step:
    the identity palette rotated (steps - base - 1) times, one index down
    per step. `base` is the step count when the range last held the
    identity (the cumulative counter also counts S6's full-range steps)."""
    count = st.last - st.first + 1
    data, steps = read_scratch(s, count)
    shift = (steps - base - 1) % count
    want = b"".join(identity_entry(st.first + ((p + shift) % count)) for p in range(count))
    expect(data == want, "%s scratch is not the identity range rotated %d (steps %d, base %d)" % (tag, shift, steps, base))


def run(s, verbose, upto):
    def show(tag, st):
        if verbose:
            print("--- %s\n%s" % (tag, st.summary()))

    def done(n):
        return upto is not None and n >= upto

    wait_text(s, "S1 cycling", STEP_WAIT_S)     # PRO 0 draws the card and starts S1
    st = wait_steps(s, 3); show("S1", st)
    expect(st.armed, "S1 HOOK_CYC armed")
    expect((st.first, st.last, st.frames) == (16, 31, 10), "S1 range 16-31 every 10 frames (got %s)" % st.summary())
    expect(st.steps >= 3, "S1 the tick steps (steps %d)" % st.steps)
    check_rotation(s, st, "S1")
    if done(1): return
    st = step(s, "S2 stopped"); show("S2", st)
    expect(not st.armed, "S2 stopped")
    steps_at_stop = st.steps
    s.wait_frames(FROZEN_FRAMES, FRAME_WAIT_S)
    expect(State(s).steps == steps_at_stop, "S2 the step counter froze after the stop")
    check_rotation(s, st, "S2")
    want = flag_rgb(16 + (steps_at_stop % 16))
    expect(read_flags(s, 121, 3) == want, "S2 GFX 120 10 on entry 16 after %d steps: want %s got %s" % (steps_at_stop, want, read_flags(s, 121, 3)))
    if done(2): return
    for n, reason, text in ((3, 2, "S3 refused"), (4, 3, "S4 refused"), (5, 1, "S5 refused")):
        st = step(s, text); show("S%d" % n, st)
        expect(not st.armed and st.reason == reason, "S%d refused with reason %d (got %s)" % (n, reason, st.summary()))
        if done(n): return
    st = step(s, "S6 full range"); show("S6", st)
    expect(st.armed and (st.first, st.last, st.frames) == (0, 254, 1), "S6 full range clamped to 254 at one frame (got %s)" % st.summary())
    base = st.steps
    st = wait_steps(s, base + 10); show("S6b", st)
    expect(st.steps >= base + 10, "S6 a 255-entry step every frame (steps %d -> %d)" % (base, st.steps))
    if done(6): return
    st = step(s, "S7 stopped"); show("S7", st)
    expect(not st.armed, "S7 stopped")
    expect(read_flags(s, 121, 3) == (224, 0, 0), "S7 GFX 9 red into 40 reads back 224,0,0 (got %s)" % (read_flags(s, 121, 3),))
    if done(7): return
    st = step(s, "S8 entry 41"); show("S8", st)
    expect(read_flags(s, 121, 3) == (224, 32, 192), "S8 the transparent colour is dodged one green step: want 224,32,192 got %s" % (read_flags(s, 121, 3),))
    if done(8): return
    st = step(s, "S9 buffered"); show("S9", st)
    expect(read_flags(s, 121, 3) == (224, 0, 0), "S9 the buffered GFX 9 survives the GFX 0 2 reveal (got %s)" % (read_flags(s, 121, 3),))
    # S9's DISPLAY 0 reloaded the card's palette, so from here row 1 holds
    # the identity again; every later prediction counts steps from k9.
    k9 = st.steps
    if done(9): return
    st = step(s, "S11 after RESTART"); show("S10/S11", st)
    expect(st.armed and st.first == 16, "S11 the cycle survives RESTART")
    base = st.steps
    st = wait_steps(s, base + 2)
    expect(st.steps >= base + 2, "S11 still stepping after RESTART")
    if done(11): return
    st = step(s, "S12 after RAMSAVE"); show("S12", st)
    expect(not st.armed, "S12 RAMLOAD stops the cycle")
    frozen = st.steps
    s.wait_frames(FROZEN_FRAMES, FRAME_WAIT_S)
    expect(State(s).steps == frozen, "S12 the step counter froze after RAMLOAD")
    if done(12): return
    s.press(DISMISS_KEY, frames=DISMISS_HOLD_FRAMES)
    took = wait_text(s, STORM_DONE, STORM_DEADLINE)
    print("cycle_dump: S13 storm done after %.1f s" % took)
    st = wait_steps(s, frozen + 6, timeout=5.0); show("S13", st)
    expect(st.armed, "S13 cycling through the storm")
    expect(st.steps > frozen + 5, "S13 the tick kept stepping under 48 pair allocations (steps %d -> %d)" % (frozen, st.steps))
    if done(13): return
    st = step(s, "S14 stopped"); show("S14", st)
    expect(not st.armed, "S14 stopped")
    rot = (st.steps - k9) % 16
    want = flag_rgb(16 + rot)
    expect(read_flags(s, 121, 3) == want, "S14 entry 16 after %d row-1 steps: want %s got %s" % (st.steps - k9, want, read_flags(s, 121, 3)))
    check_rotation(s, st, "S14", base=k9)
    print("cycle_dump: S1-S14 PASS (S15 is silicon only)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--work", default=None, help="scratch card directory")
    ap.add_argument("--upto", type=int, default=None, help="stop after step N")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    if not LEG.is_dir():
        sys.exit("cycle_dump: %s missing - run tests\\build-tests.ps1 -Cycle" % LEG)
    work = a.work or str(ROOT / "tests" / "out" / "cycle-run")
    with boot(work, a.port) as s:
        run(s, a.verbose, a.upto)


if __name__ == "__main__":
    main()
