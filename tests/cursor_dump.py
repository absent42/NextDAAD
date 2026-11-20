r"""Drives tests\cursor.dsf on CSpect (tests\cspect) and reads the cursor's tilemap cell,
the five state bytes and the resolution cache after each verb.

Run from the repo root, after
    .\build.ps1                            (DEBUG - pairReclaimCount is DEBUG-only)
    pwsh -File tests\build-tests.ps1 -Cursor

    python tests\cursor_dump.py [--upto N] [--port N] [-v]

--port is the harness MCP port (tests\cspect\launcher.py PORT_RANGE, default the first free).
Keys are type_text/press_keys frame holds; the mid-line cursor is reached with CAPS+5 (cursor
left). Waits poll the lock bytes and FRAMECOUNTER; -v also prints each check as it holds."""
import argparse
import copy
import pathlib
import shutil
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from cspect import Session                             # noqa: E402
from cspect.client import CHUNK                        # noqa: E402

LEG = ROOT / "sd" / "CURSOR"
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
TM_MAP = 0x6000
WIN_LINES, WIN_ATTR, WIN_ATTRINV, WIN_SIZE = 9, 10, 11, 12
LEFT = "CAPS+5"
DISMISS_KEY = "SYM"          # kb_char maps bare SYMBOL SHIFT to 0; wait_key takes any key
DISMISS_HOLD_FRAMES = 6
DISMISS_TRIES = 8
READY_CONFIRM_FRAMES = 5     # (moreLock, wrapLock) = (1, 1) also holds while SM32 prints
BLINK_HALF = 25              # GFX 25 23: frames per BLINK phase
WAIT_S = 60.0
POLL_S = 0.005
VERBOSE = False


def rd(s, name, n=1):
    b = s.read(s.sym(name), n)
    return b[0] if n == 1 else bytes(b)


def expect(cond, what):
    if not cond:
        sys.exit("cursor_dump: FAIL " + what)
    if VERBOSE:
        print("  ok " + what, flush=True)


class Cell:
    """The tilemap cell under the editor's cursor index."""
    def __init__(self, s, index=None):
        cur = rd(s, "INPCUR") if index is None else index
        sx, sy = rd(s, "INPSTARTX"), rd(s, "INPSTARTY")
        lo, hi = rd(s, "CURWIN", 2)
        win = s.read(lo | (hi << 8), 12)
        w = win[2]
        col, row = sx + cur, sy
        while col >= w:
            col -= w
            row += 1
        self.col, self.row = win[0] + col, win[1] + row
        self.win_attr, self.win_attrinv = win[WIN_ATTR], win[WIN_ATTRINV]
        stride = rd(s, "TMCOLS") * 2
        self.addr = TM_MAP + self.row * stride + self.col * 2
        self.glyph, self.attr = s.read(self.addr, 2)

    def again(self, s):
        """This cell re-read: same position and window, live glyph and attribute."""
        c = copy.copy(self)
        c.glyph, c.attr = s.read(self.addr, 2)
        return c

    def __repr__(self):
        return "cell(%d,%d) glyph %d attr %d [win %d inv %d]" % (
            self.row, self.col, self.glyph, self.attr, self.win_attr, self.win_attrinv)


def state(s):
    return tuple(rd(s, n) for n in ("CURGLYPH", "CURBLINK", "CURINK", "CURPAPER", "CURCOLSET"))


def cache(s):
    return tuple(rd(s, n) for n in ("CURATTR", "CURRESINK", "CURRESPAPER"))


def more_on_screen(s):
    """The pager erases its own line on the key, so its text means pending.
    Under UCASE (MODE 1) the pager prints through the upper charset, +128."""
    grid = s.read(TM_MAP, 32 * rd(s, "TMCOLS") * 2)
    text = bytes(grid[0::2])
    return b"More..." in text or bytes(c + 128 for c in b"More...") in text


def locks(s):
    """(moreLock, wrapLock) from one read when both fit one chunk."""
    a, b = s.sym("MORELOCK"), s.sym("WRAPLOCK")
    lo = min(a, b)
    if abs(a - b) < CHUNK:
        span = s.read(lo, abs(a - b) + 1)
        return span[a - lo] != 0, span[b - lo] != 0
    return s.read(a, 1)[0] != 0, s.read(b, 1)[0] != 0


def queue_empty(s):
    return rd(s, "KBQW") == rd(s, "KBQR")


def settle(s, dismiss=True):
    """Run on to the input editor with the typeahead queue drained; a More... page is
    dismissed with DISMISS_KEY, or returns "more" when dismiss is False."""
    deadline = time.monotonic() + WAIT_S
    pages = 0
    while True:
        lk = locks(s)
        if lk == (True, True) and queue_empty(s):
            s.wait_frames(READY_CONFIRM_FRAMES, WAIT_S)
            if locks(s) == (True, True):
                return None
            continue
        if lk == (True, False) and more_on_screen(s):
            if not dismiss:
                return "more"
            pages += 1
            if pages > DISMISS_TRIES:
                sys.exit("cursor_dump: FAIL a More... page would not dismiss")
            s.press(DISMISS_KEY, frames=DISMISS_HOLD_FRAMES)
            continue
        if time.monotonic() >= deadline:
            sys.exit("cursor_dump: FAIL the input editor never came back (locks %s)" % (lk,))
        time.sleep(POLL_S)


def verb(s, word):
    s.type_text(word + "\n")
    settle(s)


def wait_flag(s, n, value):
    """Poll flag n until it reaches value: a long verb's own loop counter."""
    flag = s.sym("FLAGS") + n
    try:
        s.wait_until(lambda: s.read(flag, 1)[0] >= value, WAIT_S, POLL_S)
    except TimeoutError:
        sys.exit("cursor_dump: FAIL flag %d never reached %d" % (n, value))


def keys_taken(s):
    """Every key typed so far has reached the editor, plus one frame for its redraw."""
    s.wait_until(lambda: queue_empty(s), WAIT_S, POLL_S, "the typeahead queue to drain")
    s.wait_frames(1, WAIT_S)


def type_line(s, text):
    """Type without ENTER, leaving the editor at the prompt with the line."""
    s.type_text(text)
    keys_taken(s)


def left(s, n):
    s.press(" ".join([LEFT] * n))
    keys_taken(s)


def cancel_line(s):
    """Submit whatever is typed; an unparsable line just re-prompts."""
    s.enter()
    settle(s)


def samples(s, frames):
    """The cursor's cell sampled until FRAMECOUNTER advances frames (no key: it stays put)."""
    c = Cell(s)
    out = [c]
    f0 = s.frame()
    deadline = time.monotonic() + WAIT_S
    while (s.frame() - f0) & 0xFFFF < frames:
        if time.monotonic() >= deadline:
            sys.exit("cursor_dump: FAIL FRAMECOUNTER stalled while sampling")
        out.append(c.again(s))
    return out


def check_colour(s, verbose):
    """Task 3: explicit colours, the cache, reclaim."""
    verb(s, "COLOR")
    type_line(s, "abc")
    c = Cell(s)
    expect(state(s)[2:] == (6, 0, 3), "COLOR state ink 6 paper 0 set 3 (got %s)" % (state(s),))
    expect(cache(s)[1:] == (6, 0), "COLOR cache resolved for (6, 0) (got %s)" % (cache(s),))
    expect(c.attr == cache(s)[0], "COLOR cursor cell carries curAttr: %r" % c)
    expect(c.attr not in (c.win_attr, c.win_attrinv), "COLOR cursor does not follow the window: %r" % c)
    cancel_line(s)
    verb(s, "INKON")
    type_line(s, "abc")
    c = Cell(s)
    expect(state(s)[2:] == (2, 0, 1), "INKON state ink 2, paper untouched, set 1 (got %s)" % (state(s),))
    # the block's window-derived paper is the window's INK (swapped rule)
    expect(cache(s)[1:] == (2, 5), "INKON resolved (2, window ink 5) (got %s)" % (cache(s),))
    expect(c.attr == cache(s)[0], "INKON cursor cell carries curAttr: %r" % c)
    cancel_line(s)
    verb(s, "RESET")
    type_line(s, "abc")
    c = Cell(s)
    expect(state(s)[4] == 0, "RESET clears curColSet")
    expect(c.attr == c.win_attrinv, "RESET: block follows the window swapped: %r" % c)
    cancel_line(s)
    verb(s, "COLOR")
    verb(s, "STORM")
    wait_flag(s, 100, 150)             # PRO 2's bound
    expect(rd(s, "PAIRRECLAIMCOUNT") > 0, "STORM ran pair_reclaim (count %d)" % rd(s, "PAIRRECLAIMCOUNT"))
    type_line(s, "abc")
    c = Cell(s)
    a = cache(s)[0]
    used = rd(s, "PAIRUSED", 16)
    expect(used[(a >> 1) >> 3] & (1 << ((a >> 1) & 7)), "STORM: curAttr's pair still marked in pairUsed")
    expect(c.attr == a and cache(s)[1:] == (6, 0), "STORM: cursor keeps its colours: %r cache %s" % (c, cache(s)))
    cancel_line(s)
    # pair_get matches by palette colour: (6, 0) is found in the cursor's
    # own slot only if reclaim left that slot's colours alone
    verb(s, "PROBE")
    w = Cell(s).win_attr
    expect(w == a, "PROBE: pair_get found (6,0) in the cursor's own pair - the slot kept its colours through the storm (window attr %d, curAttr %d)" % (w, a))
    verb(s, "RESET")
    if verbose:
        print("colour: PASS")


def check_glyph(s, verbose):
    """Task 4: glyph after the text, inverse on a character, charset shift."""
    verb(s, "GLYPH")
    type_line(s, "abc")
    c = Cell(s)
    expect(c.glyph == 95 and c.attr == c.win_attr, "GLYPH: underscore in the straight pair after the text: %r" % c)
    # mid-line: two cursor-lefts and x - the editor inserts at 1 and
    # redraws with the cursor on b
    left(s, 2)
    type_line(s, "x")
    expect(rd(s, "INPLINE", 5)[:4] == b"axbc", "GLYPH mid-line insert landed (line %r)" % rd(s, "INPLINE", 5))
    c = Cell(s)
    expect(c.glyph == ord("b") and c.attr == c.win_attrinv, "GLYPH on a character: inverse b: %r" % c)
    cancel_line(s)
    verb(s, "UPPER")
    type_line(s, "abc")
    c = Cell(s)
    expect(c.glyph == 223, "UPPER: tile 223 raw: %r" % c)
    cancel_line(s)
    verb(s, "BLOCK")
    type_line(s, "abc")
    c = Cell(s)
    expect(c.glyph == 32 and c.attr == c.win_attrinv, "BLOCK: inverse space after the text: %r" % c)
    cancel_line(s)
    verb(s, "UCASE")
    type_line(s, "abc")
    left(s, 2)
    type_line(s, "x")
    c = Cell(s)
    expect(c.glyph == ord("b") + 128 and c.attr == c.win_attrinv, "UCASE: the character under the cursor is shifted like the echo: %r" % c)
    prev = Cell(s, 1)
    expect(prev.glyph == ord("x") + 128 and prev.attr == c.win_attr, "UCASE: the echoed x is shifted: %r" % prev)
    cancel_line(s)
    verb(s, "LCASE")
    if verbose:
        print("glyph: PASS")


def phases(cells):
    return sorted(set(c.attr for c in cells))


def check_blink(s, verbose):
    """Task 5: both phases under BLINK and FAST, one under STEAD, visible after a key.
    Sample windows are frames: 2.5 s, 1 s and 1.5 s at 50 Hz."""
    verb(s, "BLINK")
    type_line(s, "abc")
    smp = samples(s, 125)
    c = smp[0]
    expect(phases(smp) == sorted({c.win_attr, c.win_attrinv}), "BLINK: both phases seen in 125 frames (got %s)" % phases(smp))
    expect(all(x.glyph == 32 for x in smp), "BLINK: the cell stays a space through both phases")
    # D, then the CPU stopped well inside the BLINK_HALF frames the key
    # leaves the cursor drawn; the read happens while stopped
    f0 = s.frame()
    s.press("D")
    s.pause()
    try:
        late = (s.frame() - f0) & 0xFFFF
        n = rd(s, "INPLEN")
        c2 = Cell(s)
    finally:
        s.resume()
    expect(late < BLINK_HALF, "BLINK: stopped %d frames after the key, inside the %d-frame phase" % (late, BLINK_HALF))
    expect(n == 4 and c2.attr == c.win_attrinv, "BLINK: visible right after a key (%r, len %d)" % (c2, n))
    cancel_line(s)
    verb(s, "FAST")
    type_line(s, "abc")
    smp = samples(s, 50)
    expect(len(phases(smp)) == 2, "FAST: both phases seen in 50 frames (got %s)" % phases(smp))
    cancel_line(s)
    verb(s, "STEAD")
    type_line(s, "abc")
    smp = samples(s, 75)
    expect(len(phases(smp)) == 1 and smp[0].attr == smp[0].win_attrinv, "STEAD: one phase, inverse (got %s)" % phases(smp))
    cancel_line(s)
    verb(s, "UCASE")
    verb(s, "BLINK")
    type_line(s, "abc")
    left(s, 2)
    type_line(s, "x")
    smp = samples(s, 125)
    expect(all(x.glyph == ord("b") + 128 for x in smp), "UCASE+BLINK: the shifted character survives both phases (got %s, line %r)" % (sorted(set((x.glyph, x.attr) for x in smp)), rd(s, "INPLINE", 5)))
    expect(len(phases(smp)) == 2, "UCASE+BLINK: draw and restore both seen mid-line (got %s)" % phases(smp))
    cancel_line(s)
    # spec 3.1: curGlyph is drawn raw, never charset-shifted
    verb(s, "STEAD")
    verb(s, "GLYPH")
    type_line(s, "abc")
    c = Cell(s)
    expect(c.glyph == 95, "UCASE+GLYPH: curGlyph is drawn raw, not shifted to 223: %r" % c)
    cancel_line(s)
    verb(s, "BLOCK")
    verb(s, "LCASE")
    verb(s, "STEAD")
    if verbose:
        print("blink: PASS")


def check_narrow(s, verbose):
    """Task 6: a one-row input window caps the line; the row above is untouched."""
    verb(s, "NARRO")
    above = s.read(TM_MAP + 29 * rd(s, "TMCOLS") * 2, rd(s, "TMCOLS") * 2)
    type_line(s, "a" * 90)
    expect(rd(s, "INPLEN") == 78, "NARRO: 78 characters accepted in an 80-wide row after the prompt (got %d)" % rd(s, "INPLEN"))
    expect(rd(s, "INPSTARTY") == 0, "NARRO: the origin row never scrolled (inpStartY %d)" % rd(s, "INPSTARTY"))
    expect(s.read(TM_MAP + 29 * rd(s, "TMCOLS") * 2, rd(s, "TMCOLS") * 2) == above, "NARRO: row 29 untouched")
    c = Cell(s)
    expect(c.row == 30 and c.col == 79, "NARRO: cursor on the last cell of row 30: %r" % c)
    cancel_line(s)
    verb(s, "WIDE")
    if verbose:
        print("narrow: PASS")


def check_scroll(s, verbose):
    """Task 6: a line that wraps at window 0's bottom row scrolls it; the
    origin moves up by the rows scrolled and the cursor follows."""
    for tries in range(40):
        if rd(s, "INPLEN") == 0 and rd(s, "INPSTARTY") == 15:
            break
        cancel_line(s)                 # an empty line re-prompts one row down
    else:
        sys.exit("cursor_dump: FAIL SCROLL: the prompt never reached window 0's bottom row (inpStartY %d)" % rd(s, "INPSTARTY"))
    sx, sy = rd(s, "INPSTARTX"), rd(s, "INPSTARTY")
    text = "abcdefghij" * 10
    type_line(s, text)
    expect(rd(s, "INPLEN") == 100, "SCROLL: 100 characters accepted (got %d)" % rd(s, "INPLEN"))
    # startX 1 + 100 characters + the cursor cell span two 80-wide rows
    expect(rd(s, "INPSTARTY") == sy - 1, "SCROLL: the origin moved up one row (inpStartY %d, was %d)" % (rd(s, "INPSTARTY"), sy))
    c = Cell(s)
    expect(c.row == 31 and c.col == sx + 100 - 80, "SCROLL: cursor at row 31 col %d: %r" % (sx + 20, c))
    expect(c.glyph == 32 and c.attr == c.win_attrinv, "SCROLL: the block cursor is drawn there: %r" % c)
    stride = rd(s, "TMCOLS") * 2
    first = s.read(TM_MAP + 30 * stride + sx * 2, 1)[0]
    last = s.read(TM_MAP + 31 * stride + (sx + 99 - 80) * 2, 1)[0]
    expect(first == ord(text[0]) and last == ord(text[-1]), "SCROLL: line spans row 30 col %d to row 31 col %d (glyphs %d, %d)" % (sx, sx + 19, first, last))
    cancel_line(s)
    if verbose:
        print("scroll: PASS (origin col %d row %d -> %d, %d re-prompt(s))" % (sx, sy, sy - 1, tries))


def check_lifecycle(s, verbose):
    """Task 7: RESTART, RAMLOAD and a width switch keep the cursor; paper 227 floats."""
    verb(s, "AGAIN")
    want = (95, 25, 6, 0, 3)
    expect(state(s) == want, "AGAIN: state after RESTART %s (want %s)" % (state(s), want))
    verb(s, "UNDO")
    expect(state(s) == want, "UNDO: state after RAMLOAD %s" % (state(s),))
    verb(s, "W40")
    expect(state(s) == want and rd(s, "TMCOLS") == 80, "W40: state after the width switch %s cols %d" % (state(s), rd(s, "TMCOLS")))
    verb(s, "STEAD")
    verb(s, "TRANS")
    type_line(s, "abc")
    c = Cell(s)
    expect(c.glyph == 95 and c.attr == cache(s)[0] and cache(s)[1:] == (15, 227), "TRANS: underscore in the (15, 227) pair over the card: %r cache %s" % (c, cache(s)))
    cancel_line(s)
    verb(s, "UNTRA")
    expect(state(s)[0] == 0 and state(s)[4] == 0, "UNTRA: block, window colours")
    if verbose:
        print("lifecycle: PASS")


def win_lines(s, n):
    return s.read(s.sym("WINTABLE") + n * WIN_SIZE + WIN_LINES, 1)[0]


def check_pager(s, verbose):
    """Player input restarts the More... page count in every window (jdaad
    lastPauseLine = 0 per window): 25 empty submits in 16-row window 0 never
    page. Raw ENTER only - a dismissing settle would hide the fault."""
    for n in range(1, 26):
        s.enter()
        if settle(s, dismiss=False) == "more":
            sys.exit("cursor_dump: FAIL PAGER: More... after empty submit %d" % n)
        expect(win_lines(s, 0) <= 2, "PAGER: window 0 line count %d after submit %d" % (win_lines(s, 0), n))
    # a sentinel in window 0 and window 3 proves the submit landed and
    # that the reset is not confined to the input window
    for w in (0, 3):
        s.write(s.sym("WINTABLE") + w * WIN_SIZE + WIN_LINES, bytes([9]))
    s.enter()
    if settle(s, dismiss=False) == "more":
        sys.exit("cursor_dump: FAIL PAGER: More... after the sentinel submit")
    got = (win_lines(s, 0), win_lines(s, 3))
    expect(got[0] <= 2 and got[1] == 0, "PAGER: sentinel 9 not reset by a submit (window 0 %d, window 3 %d)" % got)
    if verbose:
        print("pager: PASS")


CHECKS = [check_colour, check_glyph, check_blink, check_narrow, check_scroll, check_lifecycle, check_pager]


def run(s, verbose, upto):
    settle(s)                          # boot, PRO 0 prints the verb list
    for i, chk in enumerate(CHECKS, 1):
        chk(s, verbose)
        if upto is not None and i >= upto:
            return
    print("cursor_dump: %d check group(s) PASS" % len(CHECKS))


def main():
    global VERBOSE
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--work", default=None)
    ap.add_argument("--upto", type=int, default=None)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    VERBOSE = a.verbose
    if not LEG.is_dir():
        sys.exit("cursor_dump: %s missing - run tests\\build-tests.ps1 -Cursor" % LEG)
    sd = pathlib.Path(a.work or ROOT / "tests" / "out" / "cursor-run").resolve() / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    shutil.copytree(LEG, sd)
    shutil.copyfile(NEX, sd / "nextdaad.nex")
    with Session.boot(sd, sd / "nextdaad.nex", MAP, port=a.port) as s:
        run(s, a.verbose, a.upto)


if __name__ == "__main__":
    main()
