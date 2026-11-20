r"""Drives tests\txt40.dsf on CSpect (tests\cspect): a GFX 18 width switch keeps every window's
MODE, INK, PAPER and cached pairs, resets geometry, cursor and line count, and fills the
cleared map with window 0's attribute.

Run from the repo root, after
    .\build.ps1
    pwsh -File tests\build-tests.ps1 -Txt40

    python tests\txt40_dump.py [--port N] [-v]
    python tests\txt40_dump.py --walk COLR,MORE,COLB [--shots DIR]   (screens only, no checks)

--port is the harness MCP port (tests\cspect\launcher.py PORT_RANGE, default the first free).
--shots saves a 320x256 PNG of the display (border included) per verb. Waits are
tests\cursor_dump.py's settle (lock bytes, typeahead queue, FRAMECOUNTER).
Never types VID: video is banned from emulators (silicon only)."""
import argparse
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from cspect import Session                             # noqa: E402
from cursor_dump import settle                         # noqa: E402

LEG = ROOT / "sd" / "TXT40"
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
TM_MAP = 0x6000
TM_ROWS = 32
FULL = 80 * TM_ROWS * 2                  # the fill always covers the 80x32 region
X, Y, W, H, CURX, CURY, FLAGS, INK, PAPER, LINES, ATTR, ATTRINV = range(12)
WIN_SIZE = 12
TM_ATTR_DEFAULT, TM_ATTR_CURSOR = 0, 4
MARK = b"KEEPMARK"
W0 = (0, 6, 1)                           # window 0 MODE, INK, PAPER (txt40.dsf)
W1 = (1, 0, 4)                           # window 1 MODE, INK, PAPER
BANNED = {"VID"}


def expect(cond, what):
    if not cond:
        sys.exit("txt40_dump: FAIL " + what)


def cols(s):
    return s.read(s.sym("TMCOLS"), 1)[0]


def win(s, n):
    return s.read(s.sym("WINTABLE") + n * WIN_SIZE, WIN_SIZE)


def style(s, n):
    w = win(s, n)
    return (w[FLAGS], w[INK], w[PAPER])


def live_text(s):
    g = s.read(TM_MAP, TM_ROWS * cols(s) * 2)
    return bytes(g[0::2])


def shows(s, text):
    t = live_text(s)
    return text in t or bytes(c + 128 for c in text) in t


def cell(s, row, col):
    b = s.read(TM_MAP + row * cols(s) * 2 + col * 2, 2)
    return b[0], b[1]


def show(s, label):
    c = cols(s)
    g = s.read(TM_MAP, TM_ROWS * c * 2)
    print("--- %s (%d cols)" % (label, c))
    for r in range(TM_ROWS):
        row = bytes(g[r * c * 2:(r + 1) * c * 2:2])
        upper = any(b >= 128 for b in row)
        text = "".join(chr(b & 127) if 32 <= (b & 127) < 127 else "?" for b in row).rstrip()
        if text:
            print("%02d|%s%s" % (r, text, "   [upper charset]" if upper else ""))


def verb(s, word, dismiss=True, verbose=False):
    """Type word + ENTER and settle: True if a More... page is left pending (dismiss False)."""
    if word.upper() in BANNED:
        sys.exit("txt40_dump: refusing %s - video never runs in an emulator" % word)
    s.type_text(word + "\n")
    pending = settle(s, dismiss=dismiss) == "more"
    if verbose:
        show(s, word)
    return pending


def geometry(s, n, what):
    w = win(s, n)
    want = (0, 0, cols(s), TM_ROWS, 0, 0)
    expect(tuple(w[X:CURY + 1]) == want and w[LINES] == 0,
           "%s: window %d geometry/cursor/lines reset (got %s)" % (what, n, list(w)))


def fill_ok(s, what):
    """Row 31 and, at 40 columns, every cell past the 40x32 map carry
    window 0's attribute: only the switch's fill writes those cells."""
    a = win(s, 0)[ATTR]
    expect(a != TM_ATTR_DEFAULT, "%s: window 0 attr is not the default pair (got %d)" % (what, a))
    stride = cols(s) * 2
    row31 = s.read(TM_MAP + 31 * stride, stride)
    expect(all(row31[i] == 32 and row31[i + 1] == a for i in range(0, stride, 2)),
           "%s: row 31 blank in window 0's attr %d" % (what, a))
    if cols(s) == 40:
        tail = s.read(TM_MAP + 40 * TM_ROWS * 2, FULL - 40 * TM_ROWS * 2)
        expect(all(tail[i] == 32 and tail[i + 1] == a for i in range(0, len(tail), 2)),
               "%s: cells past the 40x32 map carry window 0's attr %d" % (what, a))


def check_boot(s, v):
    expect(cols(s) == 80, "boot: 80 columns (got %d)" % cols(s))
    for n in range(8):
        w = win(s, n)
        got = (w[FLAGS], w[INK], w[PAPER], w[ATTR], w[ATTRINV])
        expect(got == (0, 7, 0, TM_ATTR_DEFAULT, TM_ATTR_CURSOR),
               "boot: window %d white on black, MODE 0 (got %s)" % (n, got))
    if v:
        show(s, "boot")


def check_keep(s, word, target, v):
    """COLR (target 40) / COLB (target 80), then REKEY."""
    verb(s, word, verbose=v)
    expect(cols(s) == target, "%s: %d columns (got %d)" % (word, target, cols(s)))
    expect(not shows(s, MARK), "%s: KEEPMARK gone - the switch ran" % word)
    expect(style(s, 0) == W0, "%s: window 0 MODE/INK/PAPER kept (got %s, want %s)" % (word, style(s, 0), W0))
    expect(style(s, 1) == W1, "%s: window 1 MODE/INK/PAPER kept (got %s, want %s)" % (word, style(s, 1), W1))
    for n in range(2, 8):
        geometry(s, n, word)
    w0, w1 = win(s, 0), win(s, 1)
    expect(tuple(w0[X:H + 1]) == (0, 0, target, TM_ROWS), "%s: window 0 full screen (got %s)" % (word, list(w0)))
    expect(tuple(w1[X:H + 1]) == (0, 10, 40, 4), "%s: window 1 at WINAT 10 0, WINSIZE 4 40 (got %s)" % (word, list(w1)))
    g, a = cell(s, 0, 0)
    expect(g == ord("w") and a == w0[ATTR], "%s: row 0 'window zero' in window 0's attr (glyph %d attr %d, want %d)" % (word, g, a, w0[ATTR]))
    g, a = cell(s, 10, 0)
    expect(g == ord("w") + 128 and a == w1[ATTR], "%s: row 10 'window one' upper charset in window 1's attr (glyph %d attr %d)" % (word, g, a))
    fill_ok(s, word)
    before = (win(s, 0)[ATTR:], win(s, 1)[ATTR:])
    verb(s, "REKEY", verbose=v)
    after = (win(s, 0)[ATTR:], win(s, 1)[ATTR:])
    expect(before == after, "%s: kept pairs equal what INK/PAPER resolve to now (kept %s, re-resolved %s)" % (word, before, after))


def check_more(s, v):
    pending = verb(s, "MORE", dismiss=False)
    if v:
        show(s, "MORE")
    if pending:
        settle(s)
    # the verb's own 40 lines scroll KEEPMARK off, so the width is the proof:
    # the setup forced 80, so 40 now means the final switch ran
    expect(cols(s) == 40, "MORE: 40 columns (got %d)" % cols(s))
    expect(not pending, "MORE: no More... - window 0 kept MODE 2 through the switch")
    expect(style(s, 0)[0] == 2, "MORE: window 0 MODE 2 kept (got %s)" % (style(s, 0),))


def check_same(s, v):
    verb(s, "SAME", verbose=v)
    expect(cols(s) == 40, "SAME: 40 columns (got %d)" % cols(s))
    expect(shows(s, MARK), "SAME: KEEPMARK still on screen - a same-width call clears nothing")
    expect(style(s, 0) == W0, "SAME: window 0 style (got %s)" % (style(s, 0),))


def check_trns(s, v):
    verb(s, "TRNS", verbose=v)
    expect(cols(s) == 40, "TRNS: 40 columns (got %d)" % cols(s))
    expect(not shows(s, MARK), "TRNS: KEEPMARK gone - the switch ran")
    expect(style(s, 0) == (0, 7, 227), "TRNS: window 0 paper 227 kept (got %s)" % (style(s, 0),))
    fill_ok(s, "TRNS")


def check_width(s, word, target, v):
    verb(s, word, verbose=v)
    expect(cols(s) == target, "%s: %d columns (got %d)" % (word, target, cols(s)))
    for n in range(2, 8):
        geometry(s, n, word)


def check_leak(s, v):
    check_width(s, "T80", 80, v)
    verb(s, "LEAK", verbose=v)
    expect(cols(s) == 40, "LEAK: 40 columns (got %d)" % cols(s))
    t = live_text(s)
    expect(b"wid" not in t and b"switching" not in t, "LEAK: the pending fragment was discarded")


def check_wins_cent(s, width_verb, target, v):
    """WINAT/WINSIZE/CENTRE on the records win_regeom rewrote. Glyphs are
    compared with & 127: window 1 may still carry COLR's MODE 1."""
    check_width(s, width_verb, target, v)
    verb(s, "WINS", verbose=v)
    w1 = win(s, 1)
    expect(tuple(w1[X:H + 1]) == (2, 2, 36, 10), "WINS at %d: window 1 at 2,2 size 36x10 (got %s)" % (target, list(w1)))
    g, _ = cell(s, 2, 2)
    expect(g & 127 == ord("T"), "WINS at %d: the wrapped message starts at row 2 col 2 (glyph %d)" % (target, g))
    verb(s, "CENT", verbose=v)
    w2 = win(s, 2)
    x = (target - 20) // 2
    expect(tuple(w2[X:H + 1]) == (x, 0, 20, 3), "CENT at %d: window 2 centred at col %d, size 20x3 (got %s)" % (target, x, list(w2)))
    g, _ = cell(s, 0, x)
    expect(g & 127 == ord("C"), "CENT at %d: CENTRED at row 0 col %d (glyph %d)" % (target, x, g))


def run(s, v):
    settle(s)                          # boot, PRO 0 prints the verb list
    check_boot(s, v)
    # pass 1 from the 80-column boot: COLR/COLB setups are no-ops,
    # MORE/SAME/TRNS setups are real switches
    check_keep(s, "COLR", 40, v)
    check_more(s, v)
    check_keep(s, "COLB", 80, v)
    check_same(s, v)
    check_trns(s, v)
    check_leak(s, v)
    # pass 2 flips every setup: COLR/COLB real, MORE/SAME/TRNS no-ops
    check_width(s, "T40", 40, v)
    check_keep(s, "COLR", 40, v)
    check_width(s, "T80", 80, v)
    check_more(s, v)
    check_width(s, "T80", 80, v)
    check_keep(s, "COLB", 80, v)
    check_width(s, "T40", 40, v)
    check_same(s, v)
    check_width(s, "T80", 80, v)
    check_trns(s, v)
    # existing geometry verbs straight after a keep-path switch, both widths
    check_wins_cent(s, "T80", 80, v)
    check_wins_cent(s, "T40", 40, v)
    print("txt40_dump: PASS (boot, two verb orders, leak, WINS/CENT)")


def walk(s, words, shots=None):
    settle(s)
    show(s, "boot")
    for i, w in enumerate(words, 1):
        pending = verb(s, w, dismiss=False, verbose=True)
        if shots:
            png = pathlib.Path(shots).resolve() / ("%02d-%s.png" % (i, w.upper()))
            png.parent.mkdir(parents=True, exist_ok=True)
            s.screenshot().save(png)
            print("   [frame saved to %s]" % png)
        if pending:
            print("   [More... pending - dismissing]")
            settle(s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--work", default=None)
    ap.add_argument("--leg", default=str(LEG), help="card folder to boot (default sd\\TXT40)")
    ap.add_argument("--walk", default=None, help="comma-separated verbs: print screens, no checks")
    ap.add_argument("--shots", default=None, help="with --walk: save a PNG frame per verb into this folder")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    leg = pathlib.Path(a.leg)
    if not leg.is_dir():
        sys.exit("txt40_dump: %s missing - run tests\\build-tests.ps1 -Txt40" % leg)
    work = a.work or str(ROOT / "tests" / "out" / "txt40-run")
    allowed = (ROOT / "tests" / "out").resolve()
    work_path = pathlib.Path(work).resolve()
    try:
        work_path.relative_to(allowed)
    except ValueError:
        sys.exit("txt40_dump: --work must stay inside %s (got %s)" % (allowed, work_path))
    sd = work_path / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    shutil.copytree(leg, sd)
    shutil.copyfile(NEX, sd / "nextdaad.nex")
    with Session.boot(sd, sd / "nextdaad.nex", MAP, port=a.port) as s:
        if a.walk:
            walk(s, [w.strip() for w in a.walk.split(",") if w.strip()], a.shots)
        else:
            run(s, a.verbose)


if __name__ == "__main__":
    main()
