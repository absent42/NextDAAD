# Drives tests\cursor.dsf on ZEsarUX and reads the cursor's tilemap cell,
# the five state bytes and the resolution cache after each verb.
#
# Run from the repo root, after
#     .\build.ps1                            (DEBUG - pairReclaimCount is DEBUG-only)
#     pwsh -File tests\build-tests.ps1 -Cursor
#
#     python tests\cursor_dump.py [--upto N] [--port N] [-v]
#
# Keys go through send-keys-string (held for KEY_DELAY_MS, past kb_char's
# two-frame settle). The mid-line cursor is reached by POKING inpCur and
# typing one character: the left arrow is CAPS+5 and CAPS is row 0 bit 0,
# which set-ui-io-ports cannot press (zrcp.py's measured constraint). The
# silicon run sheet walks the real left arrow.
import argparse
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
LEG = ROOT / "sd" / "CURSOR"
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
TM_MAP = 0x6000
WIN_ATTR, WIN_ATTRINV = 10, 11

_MAP = {}


def sym(name):
    """CPU address of an UPPERCASE map symbol."""
    if name not in _MAP:
        for line in MAP.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.split()
            if len(parts) == 4 and parts[3] == name:
                _MAP[name] = int(parts[0], 16)
                break
        else:
            sys.exit("cursor_dump: %s not in %s - build first" % (name, MAP))
    return _MAP[name]


def rd(z, name, n=1):
    b = z.read_memory(sym(name), n)
    return b[0] if n == 1 else bytes(b)


def expect(cond, what):
    if not cond:
        sys.exit("cursor_dump: FAIL " + what)


class Cell:
    """The tilemap cell under the editor's cursor index."""
    def __init__(self, z, index=None):
        cur = rd(z, "INPCUR") if index is None else index
        sx, sy = rd(z, "INPSTARTX"), rd(z, "INPSTARTY")
        lo, hi = rd(z, "CURWIN", 2)
        win = z.read_memory(lo | (hi << 8), 12)
        w = win[2]
        col, row = sx + cur, sy
        while col >= w:
            col -= w
            row += 1
        self.col, self.row = win[0] + col, win[1] + row
        self.win_attr, self.win_attrinv = win[WIN_ATTR], win[WIN_ATTRINV]
        stride = rd(z, "TMCOLS") * 2
        b = z.read_memory(TM_MAP + self.row * stride + self.col * 2, 2)
        self.glyph, self.attr = b[0], b[1]

    def __repr__(self):
        return "cell(%d,%d) glyph %d attr %d [win %d inv %d]" % (
            self.row, self.col, self.glyph, self.attr, self.win_attr, self.win_attrinv)


def state(z):
    return tuple(rd(z, n) for n in ("CURGLYPH", "CURBLINK", "CURINK", "CURPAPER", "CURCOLSET"))


def cache(z):
    return tuple(rd(z, n) for n in ("CURATTR", "CURRESINK", "CURRESPAPER"))


def dismiss_more(z, tries=8):
    """Release any More... page: window 0's line count is not reset by an
    input, so the pager fires every 15 lines and would eat the next key.
    The pager erases its own line on the key, so its text means pending."""
    for _ in range(tries):
        grid = z.read_memory(TM_MAP, 32 * rd(z, "TMCOLS") * 2)
        if b"More..." not in bytes(grid[0::2]):
            return
        z.tap_dismiss_key()
        time.sleep(0.5)
    sys.exit("cursor_dump: FAIL a More... page would not dismiss")


def verb(z, word, settle=1.2):
    z.send_keys(word)
    z.enter(wait=settle)
    dismiss_more(z)


def wait_flag(z, n, value, deadline=60.0):
    """Poll flag n until it reaches value: a long verb's own loop counter."""
    end = time.time() + deadline
    while time.time() < end:
        if z.read_memory(sym("FLAGS") + n, 1)[0] >= value:
            return
        time.sleep(0.25)
    sys.exit("cursor_dump: FAIL flag %d never reached %d" % (n, value))


def type_line(z, text, settle=0.6):
    """Type without ENTER, leaving the editor at the prompt with the line."""
    z.send_keys(text)
    time.sleep(settle)


def cancel_line(z):
    """Submit whatever is typed; an unparsable line just re-prompts."""
    z.enter(wait=1.2)
    dismiss_more(z)


def samples(z, seconds, every=0.05, index=None):
    out = []
    end = time.time() + seconds
    while time.time() < end:
        out.append(Cell(z, index))
        time.sleep(every)
    return out


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
            sys.exit("cursor_dump: ZEsarUX exited before ZRCP came up")
        try:
            z = zrcp.Zrcp(port=port)
            break
        except OSError:
            time.sleep(0.5)
    if z is None:
        proc.kill()
        sys.exit("cursor_dump: ZRCP never answered on port %d" % port)
    z.cmd("smartload %s" % (sd / "nextdaad.nex"), deadline=60.0)
    return proc, z


def check_colour(z, verbose):
    """Task 3: explicit colours, the cache, reclaim."""
    verb(z, "COLOR")
    type_line(z, "abc")
    c = Cell(z)
    expect(state(z)[2:] == (6, 0, 3), "COLOR state ink 6 paper 0 set 3 (got %s)" % (state(z),))
    expect(cache(z)[1:] == (6, 0), "COLOR cache resolved for (6, 0) (got %s)" % (cache(z),))
    expect(c.attr == cache(z)[0], "COLOR cursor cell carries curAttr: %r" % c)
    expect(c.attr not in (c.win_attr, c.win_attrinv), "COLOR cursor does not follow the window: %r" % c)
    cancel_line(z)
    verb(z, "INKON")
    type_line(z, "abc")
    c = Cell(z)
    expect(state(z)[2:] == (2, 0, 1), "INKON state ink 2, paper untouched, set 1 (got %s)" % (state(z),))
    # the block's window-derived paper is the window's INK (swapped rule)
    expect(cache(z)[1:] == (2, 5), "INKON resolved (2, window ink 5) (got %s)" % (cache(z),))
    expect(c.attr == cache(z)[0], "INKON cursor cell carries curAttr: %r" % c)
    cancel_line(z)
    verb(z, "RESET")
    type_line(z, "abc")
    c = Cell(z)
    expect(state(z)[4] == 0, "RESET clears curColSet")
    expect(c.attr == c.win_attrinv, "RESET: block follows the window swapped: %r" % c)
    cancel_line(z)
    verb(z, "COLOR")
    verb(z, "STORM")
    wait_flag(z, 100, 150)             # PRO 2's bound; ~10 s on ZEsarUX
    time.sleep(1.5)                    # CLS, MESSAGE 19, the prompt
    dismiss_more(z)
    expect(rd(z, "PAIRRECLAIMCOUNT") > 0, "STORM ran pair_reclaim (count %d)" % rd(z, "PAIRRECLAIMCOUNT"))
    type_line(z, "abc")
    c = Cell(z)
    a = cache(z)[0]
    used = rd(z, "PAIRUSED", 16)
    expect(used[(a >> 1) >> 3] & (1 << ((a >> 1) & 7)), "STORM: curAttr's pair still marked in pairUsed")
    expect(c.attr == a and cache(z)[1:] == (6, 0), "STORM: cursor keeps its colours: %r cache %s" % (c, cache(z)))
    cancel_line(z)
    # pair_get matches by palette colour: (6, 0) is found in the cursor's
    # own slot only if reclaim left that slot's colours alone
    verb(z, "PROBE")
    w = Cell(z).win_attr
    expect(w == a, "PROBE: pair_get found (6,0) in the cursor's own pair - the slot kept its colours through the storm (window attr %d, curAttr %d)" % (w, a))
    verb(z, "RESET")
    if verbose:
        print("colour: PASS")


def check_glyph(z, verbose):
    """Task 4: glyph after the text, inverse on a character, charset shift."""
    verb(z, "GLYPH")
    type_line(z, "abc")
    c = Cell(z)
    expect(c.glyph == 95 and c.attr == c.win_attr, "GLYPH: underscore in the straight pair after the text: %r" % c)
    # mid-line: poke inpCur to 1 (a value 0-9, zrcp.write_memory's safe range)
    # and type x - the editor inserts at 1 and redraws with the cursor on b.
    z.write_memory(sym("INPCUR"), bytes([1]))
    type_line(z, "x")
    expect(rd(z, "INPLINE", 5)[:4] == b"axbc", "GLYPH mid-line insert landed (line %r)" % rd(z, "INPLINE", 5))
    c = Cell(z)
    expect(c.glyph == ord("b") and c.attr == c.win_attrinv, "GLYPH on a character: inverse b: %r" % c)
    cancel_line(z)
    verb(z, "UPPER")
    type_line(z, "abc")
    c = Cell(z)
    expect(c.glyph == 223, "UPPER: tile 223 raw: %r" % c)
    cancel_line(z)
    verb(z, "BLOCK")
    type_line(z, "abc")
    c = Cell(z)
    expect(c.glyph == 32 and c.attr == c.win_attrinv, "BLOCK: inverse space after the text: %r" % c)
    cancel_line(z)
    verb(z, "UCASE")
    type_line(z, "abc")
    z.write_memory(sym("INPCUR"), bytes([1]))
    type_line(z, "x")
    c = Cell(z)
    expect(c.glyph == ord("b") + 128 and c.attr == c.win_attrinv, "UCASE: the character under the cursor is shifted like the echo: %r" % c)
    prev = Cell(z, 1)
    expect(prev.glyph == ord("x") + 128 and prev.attr == c.win_attr, "UCASE: the echoed x is shifted: %r" % prev)
    cancel_line(z)
    verb(z, "LCASE")
    if verbose:
        print("glyph: PASS")


CHECKS = [check_colour, check_glyph]


def run(z, verbose, upto):
    time.sleep(4.0)                    # boot, PRO 0 prints the verb list
    for i, chk in enumerate(CHECKS, 1):
        chk(z, verbose)
        if upto is not None and i >= upto:
            return
    print("cursor_dump: %d check group(s) PASS" % len(CHECKS))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=10018)
    ap.add_argument("--work", default=None)
    ap.add_argument("--upto", type=int, default=None)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    if not LEG.is_dir():
        sys.exit("cursor_dump: %s missing - run tests\\build-tests.ps1 -Cursor" % LEG)
    if not port_free(a.port):
        sys.exit("cursor_dump: port %d busy" % a.port)
    work = a.work or str(ROOT / "tests" / "out" / "cursor-run")
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
