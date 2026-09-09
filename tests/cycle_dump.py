# Drives tests\cycle.dsf on ZEsarUX and checks the DEBUG snapshot, the live
# hook mask, the flags and the tick's scratch buffer after every step.
#
# Run from the repo root, after
#     .\build.ps1                            (DEBUG - the snapshot is DEBUG-only)
#     pwsh -File tests\build-tests.ps1 -Cycle
#
#     python tests\cycle_dump.py [--upto N] [--port N] [-v]
#
# The ZRCP client is tests\parser\zrcp.py (the next-emulators skill's rule).
# Snapshot layout mirrors cyc_dbg_snap in src\sprites.asm: 16 bytes at
# CYC_DBG_SNAP ($5600). The cycled range is read from cycScratch on the
# sprites page through ZEsarUX memory zone 0 (the whole 2MB, NOT indexed by
# Next page number - the page is discovered by its signatures, the way
# sprites_dump.py discovers pool pages by content); the header is read
# before and after and the read repeats until the step counter is unchanged.
import argparse
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import zrcp                                          # noqa: E402

ZESARUX = pathlib.Path(r"D:\ZXNextDev\ZEsarUX\zesarux.exe")
LEG = ROOT / "sd" / "CYCLE"
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"

SNAP = 0x5600
SNAP_LEN = 16
HOOK_CYC = 4


_MAP = {}


def map_symbol(name):
    """(cpu address, physical address) of an UPPERCASE map symbol, resolved
    lazily and cached: the Task 3 symbols do not exist before it lands, and
    the driver must still start (and fail on the snapshot) before then."""
    if name not in _MAP:
        for line in MAP.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.split()
            if len(parts) == 4 and parts[3] == name:
                _MAP[name] = (int(parts[0], 16), int(parts[1], 16))
                break
        else:
            sys.exit("cycle_dump: %s not in %s - build first" % (name, MAP))
    return _MAP[name]


SLOT7 = 0xE000                     # SPR_PAGE's CPU window under the hook
_spr_page = None


def spr_page(z):
    """Flat 8K page index of SPR_PAGE in ZEsarUX memory zone 0. Zone 0 is the
    whole 2MB but is NOT indexed by Next page number (sprites_dump.py's note:
    13.0 put page N at flat page N+32), so the page is DISCOVERED: the one
    holding "CYC1" at msgCycSig's in-page offset AND "SPR1" at msgSprSig's.
    The caller holds zone 0 selected."""
    global _spr_page
    if _spr_page is None:
        cyc_off = map_symbol("MSGCYCSIG")[0] - SLOT7
        spr_off = map_symbol("MSGSPRSIG")[0] - SLOT7
        for pg in range(256):
            if z.read_memory(pg * 8192 + cyc_off, 4) != b"CYC1":
                continue
            if z.read_memory(pg * 8192 + spr_off, 4) == b"SPR1":
                _spr_page = pg
                break
        else:
            sys.exit("cycle_dump: SPR_PAGE not found in zone 0 - no flat page holds CYC1 and SPR1 at their offsets")
    return _spr_page


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


class State:
    def __init__(self, z):
        for i in range(5):
            b = z.read_memory(SNAP, SNAP_LEN)
            if b[:4] == b"CYC1" and b[4] == b[15]:
                break
            if i == 0 and b[:4] != b"CYC1":
                sys.exit("cycle_dump: no DEBUG snapshot at $%04X: build DEBUG "
                         "last (pwsh build.ps1) before staging, and the first "
                         "GFX 11 must have run" % SNAP)
            time.sleep(0.05)
        else:
            sys.exit("cycle_dump: snapshot torn at $%04X" % SNAP)
        self.seq = b[4]
        self.first, self.last, self.frames, self.count = b[6], b[7], b[8], b[9]
        self.steps = b[10] | (b[11] << 8)
        self.reason = b[12]
        # armed comes from the LIVE mask: a stop through gfx_drawtarget_clear
        # (RAMLOAD) takes no snapshot, so the snapshot's own byte can be stale.
        self.armed = z.read_memory(map_symbol("XBNINTON")[0], 1)[0] & HOOK_CYC

    def summary(self):
        return ("seq %d armed %d range %d-%d frames %d count %d steps %d reason %d"
                % (self.seq, self.armed, self.first, self.last, self.frames,
                   self.count, self.steps, self.reason))


def read_scratch(z, count):
    """count entries (2 bytes each) from cycScratch on SPR_PAGE, read through
    zone 0 (restored to -1, mapped memory, before any other read) and
    consistent across a step: the header's step counter must read the same
    before and after."""
    off = map_symbol("CYCSCRATCH")[0] - SLOT7
    for _ in range(20):
        before = State(z).steps
        z.cmd("set-memory-zone 0")
        try:
            data = z.read_memory(spr_page(z) * 8192 + off, count * 2)
        finally:
            z.cmd("set-memory-zone -1")
        after = State(z).steps
        if before == after:
            return data
        time.sleep(0.05)
    sys.exit("cycle_dump: cycScratch never held still across a read")


def read_flags(z, first, n):
    return tuple(z.read_memory(map_symbol("FLAGS")[0] + first, n))


def expect(cond, what):
    if not cond:
        sys.exit("cycle_dump: FAIL " + what)


def step(z, settle=0.6):
    z.tap_dismiss_key()
    time.sleep(settle)
    return State(z)


def wait_steps(z, at_least, timeout=3.0):
    deadline = time.time() + timeout
    while True:
        s = State(z)
        if s.steps >= at_least or time.time() > deadline:
            return s
        time.sleep(0.1)


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
            sys.exit("cycle_dump: ZEsarUX exited before ZRCP came up")
        try:
            z = zrcp.Zrcp(port=port)
            break
        except OSError:
            time.sleep(0.5)
    if z is None:
        proc.kill()
        sys.exit("cycle_dump: ZRCP never answered on port %d" % port)
    z.cmd("smartload %s" % (sd / "nextdaad.nex"), deadline=60.0)
    return proc, z


def check_rotation(z, s, tag, base=0):
    """The scratch holds the range as the tick read it at its LAST step:
    the identity palette rotated (steps - base - 1) times, one index down
    per step. `base` is the step count when the range last held the
    identity (the cumulative counter also counts S6's full-range steps)."""
    count = s.last - s.first + 1
    data = read_scratch(z, count)
    shift = (s.steps - base - 1) % count
    want = b"".join(identity_entry(s.first + ((p + shift) % count)) for p in range(count))
    expect(data == want, "%s scratch is not the identity range rotated %d (steps %d, base %d)" % (tag, shift, s.steps, base))


def run(z, verbose, upto):
    def show(tag, s):
        if verbose:
            print("--- %s\n%s" % (tag, s.summary()))

    def done(n):
        return upto is not None and n >= upto

    time.sleep(4.0)                    # boot, PRO 0 draws the card and starts S1
    s = wait_steps(z, 3); show("S1", s)
    expect(s.armed, "S1 HOOK_CYC armed")
    expect((s.first, s.last, s.frames) == (16, 31, 10), "S1 range 16-31 every 10 frames (got %s)" % s.summary())
    expect(s.steps >= 3, "S1 the tick steps (steps %d after 4 s)" % s.steps)
    check_rotation(z, s, "S1")
    if done(1): return
    s = step(z); show("S2", s)
    expect(not s.armed, "S2 stopped")
    steps_at_stop = s.steps
    time.sleep(0.5)
    expect(State(z).steps == steps_at_stop, "S2 the step counter froze after the stop")
    check_rotation(z, s, "S2")
    want = flag_rgb(16 + (steps_at_stop % 16))
    expect(read_flags(z, 121, 3) == want, "S2 GFX 120 10 on entry 16 after %d steps: want %s got %s" % (steps_at_stop, want, read_flags(z, 121, 3)))
    if done(2): return
    for n, reason in ((3, 2), (4, 3), (5, 1)):
        s = step(z); show("S%d" % n, s)
        expect(not s.armed and s.reason == reason, "S%d refused with reason %d (got %s)" % (n, reason, s.summary()))
        if done(n): return
    s = step(z); show("S6", s)
    expect(s.armed and (s.first, s.last, s.frames) == (0, 254, 1), "S6 full range clamped to 254 at one frame (got %s)" % s.summary())
    base = s.steps
    s = wait_steps(z, base + 10); show("S6b", s)
    expect(s.steps >= base + 10, "S6 a 255-entry step every frame (steps %d -> %d)" % (base, s.steps))
    if done(6): return
    s = step(z); show("S7", s)
    expect(not s.armed, "S7 stopped")
    expect(read_flags(z, 121, 3) == (224, 0, 0), "S7 GFX 9 red into 40 reads back 224,0,0 (got %s)" % (read_flags(z, 121, 3),))
    if done(7): return
    s = step(z); show("S8", s)
    expect(read_flags(z, 121, 3) == (224, 32, 192), "S8 the transparent colour is dodged one green step: want 224,32,192 got %s" % (read_flags(z, 121, 3),))
    if done(8): return
    s = step(z, settle=1.5); show("S9", s)
    expect(read_flags(z, 121, 3) == (224, 0, 0), "S9 the buffered GFX 9 survives the GFX 0 2 reveal (got %s)" % (read_flags(z, 121, 3),))
    # S9's DISPLAY 0 reloaded the card's palette, so from here row 1 holds
    # the identity again; every later prediction counts steps from k9.
    k9 = s.steps
    if done(9): return
    s = step(z, settle=1.0); show("S10/S11", s)
    expect(s.armed and s.first == 16, "S11 the cycle survives RESTART")
    base = s.steps
    s = wait_steps(z, base + 2)
    expect(s.steps >= base + 2, "S11 still stepping after RESTART")
    if done(11): return
    s = step(z); show("S12", s)
    expect(not s.armed, "S12 RAMLOAD stops the cycle")
    frozen = s.steps
    time.sleep(0.5)
    expect(State(z).steps == frozen, "S12 the step counter froze after RAMLOAD")
    if done(12): return
    s = step(z, settle=4.0); show("S13", s)
    expect(s.armed, "S13 cycling through the storm")
    expect(s.steps > frozen + 5, "S13 the tick kept stepping under 48 pair allocations (steps %d -> %d)" % (frozen, s.steps))
    if done(13): return
    s = step(z); show("S14", s)
    expect(not s.armed, "S14 stopped")
    rot = (s.steps - k9) % 16
    want = flag_rgb(16 + rot)
    expect(read_flags(z, 121, 3) == want, "S14 entry 16 after %d row-1 steps: want %s got %s" % (s.steps - k9, want, read_flags(z, 121, 3)))
    check_rotation(z, s, "S14", base=k9)
    print("cycle_dump: S1-S14 PASS (S15 is silicon only)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=10017)
    ap.add_argument("--work", default=None, help="scratch card directory")
    ap.add_argument("--upto", type=int, default=None, help="stop after step N")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    if not LEG.is_dir():
        sys.exit("cycle_dump: %s missing - run tests\\build-tests.ps1 -Cycle" % LEG)
    if not port_free(a.port):
        sys.exit("cycle_dump: port %d busy" % a.port)
    work = a.work or str(ROOT / "tests" / "out" / "cycle-run")
    proc, z = launch(work, a.port)
    try:
        run(z, a.verbose, a.upto)
    finally:
        try:
            z.close()
        except Exception:
            pass
        proc.kill()
        proc.wait()


if __name__ == "__main__":
    main()
