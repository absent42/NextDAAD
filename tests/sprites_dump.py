r"""Drives tests\sprites.dsf on CSpect (tests\cspect) and checks the DEBUG snapshot after every
step. Layout mirrors spr_dbg_snap in src\sprites.asm; BLOCK is pinned there by an ASSERT.

Run from the repo root, after
    .\build.ps1                            (DEBUG - the snapshot is DEBUG-only)
    pwsh -File tests\build-tests.ps1 -Sprites

    python tests\sprites_dump.py [--port N] [--work DIR] [-v]

--port is the harness MCP port (tests\cspect\launcher.py PORT_RANGE, default the first free).
Each step waits for its own MESSAGE on the tilemap; samples and settles count FRAMECOUNTER.
tests\spraud_dump.py uses State, step, torch_moves, wait_text, boot and expect."""
import argparse
import os
import pathlib
import shutil
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from cspect import Session                             # noqa: E402

LEG = ROOT / "sd" / "SPRITES"
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"

SNAP = 0x5000
SR_SIZE = 48; CHANS = 8; CE_SIZE = 4; CACHE = 16
SR = dict(SET=0, KIND=1, W=2, H=3, CELLS=4, ATTR=5, PAT=6, NBLK=7, FRAMES=8, FRAME=9,
          COUNT=10, LOOP=11, CACHE=12, ROW=13, MASK=16, BLOCKS=20, X8=35, Y8=36, PATS=37,
          CHAN=39, XLO=40, Y=42)
BLOCK = 488                        # sprRec..sprLoads, ASSERT SPR_DBG_BLOCK == 488
SNAP_LEN = 4 + 1 + BLOCK + 1 + 1
PAGE = 0x2000
# Bare SYMBOL SHIFT: kb_char maps it to 0, wait_key takes any key (src\overlay1.asm, src\print.asm)
DISMISS_KEY = "SYM"
DISMISS_HOLD_FRAMES = 6
LEAVE_KEY = "SPACE"                # a GETMS loop leaves through INKEY, which ignores bare SYM
STEP_WAIT_S = 30.0                 # host deadline for a step's MESSAGE
FRAME_WAIT_S = 10.0
POLL_S = 0.02
SAMPLE_FRAMES = 4                  # torch samples: delays are 6 and 12 ticks
SAMPLE_BUDGET_FRAMES = 75


class State:
    def __init__(self, s):
        for i in range(5):
            b = s.read(SNAP, SNAP_LEN)
            if b[:4] == b"SPR1" and b[4] == b[-1]:
                break
            # no signature on the first read is a Release .nex: nothing writes $5000 there
            if i == 0 and b[:4] != b"SPR1":
                sys.exit("sprites_dump: no DEBUG snapshot at $%04X: build DEBUG "
                         "last (pwsh build.ps1) before staging" % SNAP)
            s.wait_frames(1, FRAME_WAIT_S)
        else:
            sys.exit("sprites_dump: snapshot torn at $%04X" % SNAP)
        self.seq = b[4]
        blob = b[5:5 + BLOCK]
        self.recs = [blob[i*SR_SIZE:(i+1)*SR_SIZE] for i in range(CHANS)]
        o = CHANS * SR_SIZE
        self.half = blob[o:o+16]; self.attr = blob[o+16:o+32]
        self.ident = blob[o+32] | blob[o+33] << 8
        self.claim = blob[o+34] | blob[o+35] << 8
        self.pointer = blob[o+36] | blob[o+37] << 8
        self.cache = [blob[o+38+i*CE_SIZE:o+38+(i+1)*CE_SIZE] for i in range(CACHE)]
        self.loads = blob[o+38+CACHE*CE_SIZE+1]
        self.hook = b[5 + BLOCK]

    def live(self):
        return {r[SR["SET"]]: r for r in self.recs if r[SR["SET"]] != 255}

    def cached(self):
        return sorted(e[0] for e in self.cache if e[0] != 255)

    def summary(self):
        r = self.live()
        parts = ["loads=%d hook=%02X ident=%04X claim=%04X pointer=%04X cached=%r"
                 % (self.loads, self.hook, self.ident, self.claim, self.pointer,
                    self.cached())]
        for n in sorted(r):
            v = r[n]
            parts.append("  set %3d kind=%d W=%d H=%d cells=%d pats=%d pat=%d attr=%d "
                         "frames=%d chan=%d x=%d y=%d blocks=%r"
                         % (n, v[SR["KIND"]], v[SR["W"]], v[SR["H"]], v[SR["CELLS"]],
                            v[SR["PATS"]], v[SR["PAT"]], v[SR["ATTR"]], v[SR["FRAMES"]],
                            v[SR["CHAN"]], v[SR["XLO"]], v[SR["Y"]],
                            list(v[SR["BLOCKS"]:SR["BLOCKS"] + v[SR["NBLK"]]])))
        return "\n".join(parts)


def pool_pages_hold(s, ani, bank0, bank1):
    """True when the file's three 8K reads sit in pool pages bank0*2, bank0*2+1 and bank1*2
    (spr_cache_page: page = CE_BANKn * 2 + image page within the bank)."""
    parts = ((bank0 * 2, ani[:PAGE]), (bank0 * 2 + 1, ani[PAGE:2 * PAGE]), (bank1 * 2, ani[2 * PAGE:]))
    return all(s.read_page(pg, 0, len(want)) == want for pg, want in parts)


def expect(cond, what):
    if not cond:
        sys.exit("sprites_dump: FAIL " + what)


def on_screen(s, text):
    return any(text in r for r in s.rows())


def wait_text(s, text, timeout=STEP_WAIT_S):
    """True once text is on the tilemap, False after timeout seconds."""
    try:
        s.wait_until(lambda: on_screen(s, text), timeout, POLL_S, repr(text))
        return True
    except TimeoutError:
        return False


def step(s, text, until=None, timeout=3.0, pre=0):
    """Leave the current wait, then read the snapshot once text (the next step's MESSAGE) is on
    the tilemap. until: the wait is a GETMS tracking loop (SPACE leaves it) and the snapshot is
    polled until until(state) or timeout seconds. pre: frames to run before the key."""
    if pre:
        s.wait_frames(pre, FRAME_WAIT_S)
    if until is None:
        s.press(DISMISS_KEY, frames=DISMISS_HOLD_FRAMES)
    else:
        s.press(LEAVE_KEY)
    if not wait_text(s, text):
        sys.exit("sprites_dump: FAIL %r never printed\n%s" % (text, State(s).summary()))
    st = State(s)
    deadline = time.monotonic() + timeout
    while until is not None and not until(st) and time.monotonic() < deadline:
        time.sleep(POLL_S)
        st = State(s)
    return st


def torch_moves(s, n):
    """(moved, pairs): set n's (frame, count) pair sampled every SAMPLE_FRAMES; at least
    three samples, then until it moves or SAMPLE_BUDGET_FRAMES pass. The pair is
    2-valued over an 18-tick period, so a fixed gap can alias."""
    r = State(s).live()
    pairs = [(r[n][SR["FRAME"]], r[n][SR["COUNT"]])]
    f0 = s.frame()
    while True:
        s.wait_frames(SAMPLE_FRAMES, FRAME_WAIT_S)
        r = State(s).live()
        if n not in r:
            return False, pairs
        pairs.append((r[n][SR["FRAME"]], r[n][SR["COUNT"]]))
        moved = any(p != pairs[0] for p in pairs[1:])
        if len(pairs) >= 3 and (moved or (s.frame() - f0) & 0xFFFF >= SAMPLE_BUDGET_FRAMES):
            return moved, pairs


def boot(work, leg=LEG, port=None):
    """A Session on a scratch copy of leg (sd\\SPRITES unless tests\\spraud_dump.py passes
    its own) with the built .nex."""
    sd = pathlib.Path(work).resolve() / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    shutil.copytree(leg, sd)
    shutil.copyfile(NEX, sd / "nextdaad.nex")
    return Session.boot(sd, sd / "nextdaad.nex", MAP, port=port)


def run(s, verbose):
    def show(tag, st):
        if verbose:
            print("--- %s\n%s" % (tag, st.summary()))
    # PRO 0 runs MOUSE 0 1, GFX 2 19, MESSAGE 0 at boot
    expect(wait_text(s, "S1 GFX 2 19"), "S1 message never printed")
    st = State(s); show("S1", st)
    expect(st.pointer == 0x8001, "S1 pointerMask $8001 for the built-in arrow (got %04X)" % st.pointer)
    r = st.live(); expect(list(r) == [2], "S1 set 2 live, got %r" % list(r))
    expect(r[2][SR["KIND"]] == 0 and r[2][SR["PATS"]] == 2 and r[2][SR["PAT"]] == 2, "S1 8-bit, 2 patterns at half-slot 2")
    expect(r[2][SR["ATTR"]] == 127, "S1 attribute run top-down at 127")
    expect(r[2][SR["XLO"]] == 56 and r[2][SR["Y"]] == 212, "S1 (24,180) in 256x192 mode is plane (56,212)")
    expect(st.loads == 1 and st.cached() == [2], "S1 one SD load, set 2 cached")
    expect(st.hook & 2, "S1 HOOK_SPR armed")
    # the tick refreshes SR_FRAME/SR_COUNT only on an advance: (0,6) for six ticks, (1,12) for twelve
    moved, pairs = torch_moves(s, 2)
    expect(moved, "S1 torch advances (delays 6 and 12 ticks): %r" % (pairs,))
    expect(all(p[0] in (0, 1) for p in pairs),
           "S1 torch stays inside its two frames: %r" % (pairs,))
    st = step(s, "S2 GFX 6 19", until=lambda x: 6 in x.live()); show("S2", st); r = st.live()
    expect(sorted(r) == [2, 6], "S2 sets 2 and 6 live")
    expect(r[6][SR["KIND"]] == 1 and r[6][SR["NBLK"]] == 2 and list(r[6][SR["BLOCKS"]:SR["BLOCKS"]+2]) == [1, 2], "S2 4-bit claims blocks 1,2")
    expect(st.claim == 0b110 and r[6][SR["ATTR"]] == 126 and r[6][SR["PAT"]] == 6, "S2 claim mask, attr 126, half-slot 6")
    st = step(s, "S3 GFX 15 19", until=lambda x: x.loads >= 3); show("S3", st); r = st.live()
    expect(sorted(r) == [2, 6] and st.loads == 3 and 15 in st.cached(), "S3 15 refused (block 2 claimed) but cached")
    st = step(s, "S4 GFX 6 21"); show("S4", st); r = st.live()
    expect(sorted(r) == [2] and st.claim == 0, "S4 set 6 stopped, claim cleared")
    st = step(s, "S5 GFX 15 19"); show("S5", st); r = st.live()
    expect(sorted(r) == [2, 15] and st.loads == 3 and r[15][SR["ATTR"]] == 126, "S5 15 starts from cache")
    expect(st.ident == (0x8001 | (1 << 2)), "S5 identity mask includes block 2")
    st = step(s, "S6 GFX 255 21"); show("S6", st); r = st.live()
    expect(r == {} and not (st.hook & 2) and st.ident == 0x8001, "S6 stop-all: no records, hook disarmed")
    st = step(s, "S7 GFX 100 20"); show("S7", st); r = st.live()
    expect(list(r) == [3] and r[3][SR["CELLS"]] == 4 and r[3][SR["ATTR"]] == 124 and r[3][SR["PATS"]] == 3, "S7 set 3 via flags")
    expect(r[3][SR["XLO"]] == 72 and r[3][SR["Y"]] == 132, "S7 override (40,100) is plane (72,132)")
    # 003.ANI is two frames, no loop: the tick parks on frame 1 with SR_COUNT 0
    s.wait_frames(25, FRAME_WAIT_S); st = State(s); r = st.live()
    expect(r[3][SR["FRAME"]] == 1 and r[3][SR["COUNT"]] == 0, "S7 one-shot holds its last frame")
    seq7 = st.seq
    st = step(s, "S8 GFX 253 20"); show("S8", st); r = st.live()
    expect(list(r) == [3], "S8 GFX 253 20 refused, state unchanged")
    # f > 252 goes through spr_refuse (reason 0C), and every refusal writes the snapshot
    expect(st.seq != seq7, "S8 the refusal took a snapshot (seq stuck at %d)" % seq7)
    st = step(s, "S9 eight starts"); show("S9", st); r = st.live()
    expect(sorted(r) == list(range(20, 28)) and st.loads == 12, "S9 eight live, 28 refused before any read: %r loads=%d" % (sorted(r), st.loads))
    st = step(s, "S10 restart of a live set"); show("S10", st); r = st.live()
    expect(list(r) == [2] and st.loads == 12, "S10 restart of a live set is not a load (loads=%d)" % st.loads)
    st = step(s, "S11 two-bank set"); show("S11", st); r = st.live()
    expect(list(r) == [17], "S11 set 17 live, got %r" % list(r))
    expect(r[17][SR["KIND"]] == 1 and r[17][SR["PATS"]] == 126, "S11 4-bit with 126 patterns")
    ent = st.cache[r[17][SR["CACHE"]]]
    expect(ent[0] == 17 and ent[2] != 255, "S11 017.ANI is over 16K: its entry holds two banks (CE_BANK1=%d)" % ent[2])
    expect(st.loads == 13, "S11 one more SD load (loads=%d)" % st.loads)
    # 16810 bytes: 8K into bank0 page 0, 8K into bank0 page 1, the 426-byte tail into bank1 page 0
    ani = (LEG / "017.ANI").read_bytes()
    expect(pool_pages_hold(s, ani, ent[1], ent[2]),
           "S11 017.ANI is in bank %d pages 0-1 and bank %d page 0 - the second-bank read "
           "kept its image-page index" % (ent[1], ent[2]))
    st = step(s, "S12 cache full"); show("S12", st); r = st.live()
    # the fourth load is the seventeenth and evicts; the victim scan's counter must survive
    # its nested liveness check, which only a full cache shows
    expect(len(st.cached()) == 16, "S12 cache full at 16 entries, got %r" % (st.cached(),))
    expect(sorted(r) == [29, 30, 31, 32], "S12 sets 29-32 live, got %r" % sorted(r))
    for n in (29, 30, 31, 32):
        ent = st.cache[r[n][SR["CACHE"]]]
        expect(ent[0] == n, "S12 set %d still owns cache entry %d (it holds %d)"
               % (n, r[n][SR["CACHE"]], ent[0]))
    expect(st.loads == 17, "S12 four more SD loads (loads=%d)" % st.loads)
    # LRU: set 6 went at S12, so set 15 (last touched at S5) is the coldest non-live entry
    prev = st.cached()
    st = step(s, "S13 set 33 evicts"); show("S13", st); r = st.live()
    expect(sorted(r) == [29, 30, 31, 32, 33], "S13 sets 29-33 live, got %r" % sorted(r))
    expect(st.loads == 18, "S13 one more SD load (loads=%d)" % st.loads)
    expect(len(st.cached()) == 16, "S13 cache still full at 16 entries, got %r" % (st.cached(),))
    expect(33 in st.cached(), "S13 set 33 is cached, got %r" % (st.cached(),))
    expect(15 not in st.cached(),
           "S13 the coldest non-live entry (set 15) was evicted to make room; "
           "cache was %r, now %r" % (prev, st.cached()))
    for n in (29, 30, 31, 32):
        expect(n in st.cached(), "S13 live set %d was NOT evicted (cache %r)" % (n, st.cached()))
    st = step(s, "S14 4-bit composite"); show("S14", st); r = st.live()
    expect(list(r) == [18], "S14 set 18 live, got %r" % list(r))
    v = r[18]
    expect(v[SR["KIND"]] == 1 and v[SR["CELLS"]] == 4 and v[SR["PATS"]] == 8,
           "S14 4-bit, four cells, eight patterns (kind=%d cells=%d pats=%d)"
           % (v[SR["KIND"]], v[SR["CELLS"]], v[SR["PATS"]]))
    expect(v[SR["NBLK"]] >= 2, "S14 at least two palette blocks (NBLK=%d)" % v[SR["NBLK"]])
    expect(v[SR["ATTR"]] == 124, "S14 anchor attribute 124 for four cells (got %d)" % v[SR["ATTR"]])
    st = step(s, "S15 PICTURE stops all", until=lambda x: x.live() == {}); show("S15", st); r = st.live()
    expect(r == {} and not (st.hook & 2) and 2 in st.cached(), "S15 PICTURE stops all, cache kept")
    # torch, not set 3: set 3's green is index $1C in block 1, which the 4-bit composite claims
    st = step(s, "S16 320-wide", until=lambda x: 18 in x.live() and 2 in x.live(), pre=75)
    show("S16", st); r = st.live()
    expect(sorted(r) == [2, 18], "S16 composite and torch live over the 320-wide picture, got %r" % sorted(r))
    expect(r[2][SR["XLO"]] == 200 and r[2][SR["X8"]] == 0 and r[2][SR["Y"]] == 100,
           "S16 320 mode: picture (200,100) is plane (200,100), no offset (got %d,%d)" % (r[2][SR["XLO"]], r[2][SR["Y"]]))
    expect(r[18][SR["XLO"]] == 0 and r[18][SR["Y"]] == 0, "S16 320 mode: picture (0,0) is plane (0,0)")
    print("sprites_dump: S1-S16 pass")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--work", default=None, help="scratch card directory")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print the decoded snapshot at every step")
    args = ap.parse_args()
    if not NEX.exists():
        sys.exit("build\\nextdaad.nex missing - run .\\build.ps1 (DEBUG)")
    if not (LEG / "GAME.DDB").exists():
        sys.exit("sd\\SPRITES\\GAME.DDB missing - run tests\\build-tests.ps1 -Sprites")
    work = args.work or os.path.join(os.environ.get("TEMP", "."), "sprites_dump")
    os.makedirs(work, exist_ok=True)
    with boot(work, port=args.port) as s:
        return run(s, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
