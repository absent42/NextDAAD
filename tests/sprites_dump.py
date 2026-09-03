# Drives tests\sprites.dsf on ZEsarUX and checks the DEBUG snapshot after every
# step. Layout mirrors spr_dbg_snap in src\sprites.asm; BLOCK is pinned there
# by an ASSERT.
#
# Run from the repo root, after
#     .\build.ps1                            (DEBUG - the snapshot is DEBUG-only)
#     pwsh -File tests\build-tests.ps1 -Sprites
#
#     python tests\sprites_dump.py [--port N]
#
# The ZRCP client is tests\parser\zrcp.py, not a fresh socket client (the
# next-emulators skill's rule). Each ANYKEY is released with SYMBOL SHIFT
# through the emulated keyboard matrix - see zrcp.tap_dismiss_key for why
# that key and not SPACE.
import argparse
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import zrcp                                          # noqa: E402

ZESARUX = pathlib.Path(r"D:\ZXNextDev\ZEsarUX\zesarux.exe")
LEG = ROOT / "sd" / "SPRITES"
NEX = ROOT / "build" / "nextdaad.nex"

SNAP = 0x5000
SR_SIZE = 48; CHANS = 8; CE_SIZE = 4; CACHE = 16
SR = dict(SET=0, KIND=1, W=2, H=3, CELLS=4, ATTR=5, PAT=6, NBLK=7, FRAMES=8, FRAME=9,
          COUNT=10, LOOP=11, CACHE=12, ROW=13, MASK=16, BLOCKS=20, X8=35, Y8=36, PATS=37,
          CHAN=39, XLO=40, XHI=41, Y=42)
BLOCK = 488                        # sprRec..sprLoads, ASSERT SPR_DBG_BLOCK == 488
SNAP_LEN = 4 + 1 + BLOCK + 1 + 1


class State:
    def __init__(self, z):
        for _ in range(5):
            b = z.read_memory(SNAP, SNAP_LEN)
            if b[:4] == b"SPR1" and b[4] == b[-1]:
                break
            time.sleep(0.05)
        else:
            sys.exit("sprites_dump: snapshot torn or missing at $%04X" % SNAP)
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


def pool_pages_hold(z, ani, page_gap):
    """True when three consecutive-by-bank pool pages hold 017.ANI's three
    8K reads: the file head, the bytes at 8192, and the tail at 16384.

    ZEsarUX zone 0 is the machine's whole 2MB of RAM, so it sees a pool bank
    the CPU has not mapped - but it is NOT indexed by Next MMU page number
    (13.0 put page N at flat page N+32), so the head's page is DISCOVERED and
    the other two are addressed relative to it. That keeps the check free of
    any emulator-layout constant. `page_gap` is (CE_BANK1 - CE_BANK0) * 2, the
    distance in 8K pages from the first bank's page 0 to the second's.
    Zone -1 (mapped memory) is restored before returning - every other read in
    this file is CPU-visible.
    """
    z.cmd("set-memory-zone 0")
    try:
        head, mid, tail = ani[:16], ani[8192:8208], ani[16384:16400]
        for pg in range(256):
            if z.read_memory(pg * 8192, 16) != head:
                continue
            if pg + 1 > 255 or z.read_memory((pg + 1) * 8192, 16) != mid:
                continue
            if pg + page_gap > 255:
                continue
            if z.read_memory((pg + page_gap) * 8192, 16) == tail:
                return True
        return False
    finally:
        z.cmd("set-memory-zone -1")


def expect(cond, what):
    if not cond:
        sys.exit("sprites_dump: FAIL " + what)


def step(z):
    z.tap_dismiss_key()
    time.sleep(0.6)
    return State(z)


def port_free(port):
    s = socket.socket()
    try:
        s.connect(("127.0.0.1", port))
    except OSError:
        return True
    finally:
        s.close()
    return False


def launch(work, port):
    """Stage sd\\SPRITES into an absolute scratch card, boot it headless and
    return (process, connected client)."""
    sd = pathlib.Path(work).resolve() / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    shutil.copytree(LEG, sd)
    shutil.copyfile(NEX, sd / "nextdaad.nex")
    proc = subprocess.Popen([
        str(ZESARUX), "--machine", "tbblue", "--realvideo",
        "--enable-esxdos-handler", "--esxdos-root-dir", str(sd),
        "--vo", "null", "--ao", "null",
        "--enable-remoteprotocol", "--remoteprotocol-port", str(port),
        "--smartloadpath", str(sd),
    ], cwd=str(sd))
    z = None
    for _ in range(60):
        if proc.poll() is not None:
            proc.wait()
            sys.exit("sprites_dump: ZEsarUX exited before ZRCP came up")
        try:
            z = zrcp.Zrcp(port=port)
            break
        except OSError:
            time.sleep(0.5)
    if z is None:
        proc.kill()
        sys.exit("sprites_dump: ZRCP never answered on port %d" % port)
    z.cmd("smartload %s" % (sd / "nextdaad.nex"), deadline=60.0)
    return proc, z


def run(z, verbose):
    def show(tag, s):
        if verbose:
            print("--- %s\n%s" % (tag, s.summary()))
    time.sleep(4.0)                    # PRO 0 runs MOUSE 0 1, GFX 2 19, MESSAGE 0 at boot
    s = State(z); show("S1", s)
    expect(s.pointer == 0x8001, "S1 pointerMask $8001 for the built-in arrow (got %04X)" % s.pointer)
    r = s.live(); expect(list(r) == [2], "S1 set 2 live, got %r" % list(r))
    expect(r[2][SR["KIND"]] == 0 and r[2][SR["PATS"]] == 2 and r[2][SR["PAT"]] == 2, "S1 8-bit, 2 patterns at half-slot 2")
    expect(r[2][SR["ATTR"]] == 127, "S1 attribute run top-down at 127")
    expect(r[2][SR["XLO"]] == 56 and r[2][SR["Y"]] == 212, "S1 (24,180) in 256x192 mode is plane (56,212)")
    expect(s.loads == 1 and s.cached() == [2], "S1 one SD load, set 2 cached")
    expect(s.hook & 2, "S1 HOOK_SPR armed")
    # The tick refreshes SR_FRAME/SR_COUNT in the snapshot for every channel
    # it visits, so a live set's pair has to move on its own between reads.
    f0 = r[2][SR["FRAME"]]; c0 = r[2][SR["COUNT"]]
    time.sleep(0.5); s = State(z); r = s.live()
    expect((r[2][SR["FRAME"]], r[2][SR["COUNT"]]) != (f0, c0), "S1 torch advances (delays 6 and 12 ticks)")
    s = step(z); show("S2", s); r = s.live()
    expect(sorted(r) == [2, 6], "S2 sets 2 and 6 live")
    expect(r[6][SR["KIND"]] == 1 and r[6][SR["NBLK"]] == 2 and list(r[6][SR["BLOCKS"]:SR["BLOCKS"]+2]) == [1, 2], "S2 4-bit claims blocks 1,2")
    expect(s.claim == 0b110 and r[6][SR["ATTR"]] == 126 and r[6][SR["PAT"]] == 6, "S2 claim mask, attr 126, half-slot 6")
    s = step(z); show("S3", s); r = s.live()
    expect(sorted(r) == [2, 6] and s.loads == 3 and 15 in s.cached(), "S3 15 refused (block 2 claimed) but cached")
    s = step(z); show("S4", s); r = s.live()
    expect(sorted(r) == [2] and s.claim == 0, "S4 set 6 stopped, claim cleared")
    s = step(z); show("S5", s); r = s.live()
    expect(sorted(r) == [2, 15] and s.loads == 3 and r[15][SR["ATTR"]] == 126, "S5 15 starts from cache")
    expect(s.ident == (0x8001 | (1 << 2)), "S5 identity mask includes block 2")
    s = step(z); show("S6", s); r = s.live()
    expect(r == {} and not (s.hook & 2) and s.ident == 0x8001, "S6 stop-all: no records, hook disarmed")
    s = step(z); show("S7", s); r = s.live()
    expect(list(r) == [3] and r[3][SR["CELLS"]] == 4 and r[3][SR["ATTR"]] == 124 and r[3][SR["PATS"]] == 3, "S7 set 3 via flags")
    expect(r[3][SR["XLO"]] == 72 and r[3][SR["Y"]] == 132, "S7 override (40,100) is plane (72,132)")
    # 003.ANI is two frames, no loop: frame 1's delay runs out and the tick
    # parks there with SR_COUNT 0 rather than wrapping.
    time.sleep(0.5); s = State(z); r = s.live()
    expect(r[3][SR["FRAME"]] == 1 and r[3][SR["COUNT"]] == 0, "S7 one-shot holds its last frame")
    s = step(z); show("S8", s); r = s.live()
    expect(list(r) == [3], "S8 GFX 253 20 refused, state unchanged")
    s = step(z); show("S9", s); r = s.live()
    expect(sorted(r) == list(range(20, 28)) and s.loads == 12, "S9 eight live, 28 refused before any read: %r loads=%d" % (sorted(r), s.loads))
    s = step(z); show("S10", s); r = s.live()
    expect(list(r) == [2] and s.loads == 12, "S10 restart of a live set is not a load (loads=%d)" % s.loads)
    s = step(z); show("S11", s); r = s.live()
    expect(list(r) == [17], "S11 set 17 live, got %r" % list(r))
    expect(r[17][SR["KIND"]] == 1 and r[17][SR["PATS"]] == 126, "S11 4-bit with 126 patterns")
    ent = s.cache[r[17][SR["CACHE"]]]
    expect(ent[0] == 17 and ent[2] != 255, "S11 017.ANI is over 16K: its entry holds two banks (CE_BANK1=%d)" % ent[2])
    expect(s.loads == 13, "S11 one more SD load (loads=%d)" % s.loads)
    # The file is 16810 bytes: 8K into bank0 page 0, 8K into bank0 page 1, the
    # 426-byte tail into bank1 page 0. Read the pool banks straight out of the
    # machine's RAM - nothing maps them at this point, and a lost page index on
    # the second-bank read would put that tail somewhere else entirely.
    ani = (LEG / "017.ANI").read_bytes()
    expect(pool_pages_hold(z, ani, (ent[2] - ent[1]) * 2),
           "S11 the 426-byte tail landed in bank1 page 0 - the second-bank read "
           "kept its image-page index (banks %d and %d)" % (ent[1], ent[2]))
    s = step(z); show("S12", s); r = s.live()
    # Thirteen entries were already cached, so the fourth of these four loads
    # is the seventeenth and has to evict. The scan that picks the victim runs
    # a nested liveness check over the records, and its own counter has to
    # survive that - a full cache is the only shape where losing it shows.
    expect(len(s.cached()) == 16, "S12 cache full at 16 entries, got %r" % (s.cached(),))
    expect(sorted(r) == [29, 30, 31, 32], "S12 sets 29-32 live, got %r" % sorted(r))
    for n in (29, 30, 31, 32):
        ent = s.cache[r[n][SR["CACHE"]]]
        expect(ent[0] == n, "S12 set %d still owns cache entry %d (it holds %d)"
               % (n, r[n][SR["CACHE"]], ent[0]))
    expect(s.loads == 17, "S12 four more SD loads (loads=%d)" % s.loads)
    s = step(z); show("S13", s)
    print("sprites_dump: S1-S12 pass (S13 is Task 9)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=10016)
    ap.add_argument("--work", default=None, help="scratch card directory")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print the decoded snapshot at every step")
    args = ap.parse_args()
    if not ZESARUX.exists():
        sys.exit("ZEsarUX not found at %s" % ZESARUX)
    if not NEX.exists():
        sys.exit("build\\nextdaad.nex missing - run .\\build.ps1 (DEBUG)")
    if not (LEG / "GAME.DDB").exists():
        sys.exit("sd\\SPRITES\\GAME.DDB missing - run tests\\build-tests.ps1 -Sprites")
    if not port_free(args.port):
        sys.exit("port %d is already listening - a stale emulator would be measured "
                 "instead of a fresh one" % args.port)
    work = args.work or os.path.join(os.environ.get("TEMP", "."), "sprites_dump")
    os.makedirs(work, exist_ok=True)
    proc, z = launch(work, args.port)
    try:
        return run(z, args.verbose)
    finally:
        try:
            z.close()
        except Exception:
            pass
        proc.kill()
        proc.wait(timeout=20)


if __name__ == "__main__":
    sys.exit(main())
