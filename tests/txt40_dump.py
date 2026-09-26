# Drives tests\txt40.dsf on ZEsarUX: a GFX 18 width switch keeps every
# window's MODE, INK, PAPER and cached pairs, resets geometry, cursor and
# line count, and fills the cleared map with window 0's attribute.
#
# Run from the repo root, after
#     .\build.ps1
#     pwsh -File tests\build-tests.ps1 -Txt40
#
#     python tests\txt40_dump.py [--port N] [-v]
#     python tests\txt40_dump.py --walk COLR,MORE,COLB   (screens only, no checks)
#
# Never types VID: video is banned from emulators (silicon only).
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

_MAP = {}


def sym(name):
    if name not in _MAP:
        for line in MAP.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.split()
            if len(parts) == 4 and parts[3] == name:
                _MAP[name] = int(parts[0], 16)
                break
        else:
            sys.exit("txt40_dump: %s not in %s - build first" % (name, MAP))
    return _MAP[name]


def expect(cond, what):
    if not cond:
        sys.exit("txt40_dump: FAIL " + what)


def cols(z):
    return z.read_memory(sym("TMCOLS"), 1)[0]


def win(z, n):
    return bytes(z.read_memory(sym("WINTABLE") + n * WIN_SIZE, WIN_SIZE))


def style(z, n):
    w = win(z, n)
    return (w[FLAGS], w[INK], w[PAPER])


def live_text(z):
    g = z.read_memory(TM_MAP, TM_ROWS * cols(z) * 2)
    return bytes(g[0::2])


def shows(z, text):
    t = live_text(z)
    return text in t or bytes(c + 128 for c in text) in t


def cell(z, row, col):
    b = z.read_memory(TM_MAP + row * cols(z) * 2 + col * 2, 2)
    return b[0], b[1]


def show(z, label):
    c = cols(z)
    g = z.read_memory(TM_MAP, TM_ROWS * c * 2)
    print("--- %s (%d cols)" % (label, c))
    for r in range(TM_ROWS):
        row = bytes(g[r * c * 2:(r + 1) * c * 2:2])
        upper = any(b >= 128 for b in row)
        text = "".join(chr(b & 127) if 32 <= (b & 127) < 127 else "?" for b in row).rstrip()
        if text:
            print("%02d|%s%s" % (r, text, "   [upper charset]" if upper else ""))


def more_on_screen(z):
    return shows(z, b"More...")


def dismiss_more(z, tries=8):
    for _ in range(tries):
        if not more_on_screen(z):
            return
        z.tap_dismiss_key()
        time.sleep(0.5)
    sys.exit("txt40_dump: FAIL a More... page would not dismiss")


def verb(z, word, settle=2.5, dismiss=True, verbose=False):
    if word.upper() in BANNED:
        sys.exit("txt40_dump: refusing %s - video never runs in an emulator" % word)
    z.send_keys(word)
    z.enter(wait=settle)
    if dismiss:
        dismiss_more(z)
    if verbose:
        show(z, word)


def geometry(z, n, what):
    w = win(z, n)
    want = (0, 0, cols(z), TM_ROWS, 0, 0)
    expect(tuple(w[X:CURY + 1]) == want and w[LINES] == 0,
           "%s: window %d geometry/cursor/lines reset (got %s)" % (what, n, list(w)))


def fill_ok(z, what):
    """Row 31 and, at 40 columns, every cell past the 40x32 map carry
    window 0's attribute: only the switch's fill writes those cells."""
    a = win(z, 0)[ATTR]
    expect(a != TM_ATTR_DEFAULT, "%s: window 0 attr is not the default pair (got %d)" % (what, a))
    stride = cols(z) * 2
    row31 = z.read_memory(TM_MAP + 31 * stride, stride)
    expect(all(row31[i] == 32 and row31[i + 1] == a for i in range(0, stride, 2)),
           "%s: row 31 blank in window 0's attr %d" % (what, a))
    if cols(z) == 40:
        tail = z.read_memory(TM_MAP + 40 * TM_ROWS * 2, FULL - 40 * TM_ROWS * 2)
        expect(all(tail[i] == 32 and tail[i + 1] == a for i in range(0, len(tail), 2)),
               "%s: cells past the 40x32 map carry window 0's attr %d" % (what, a))


def check_boot(z, v):
    expect(cols(z) == 80, "boot: 80 columns (got %d)" % cols(z))
    for n in range(8):
        w = win(z, n)
        got = (w[FLAGS], w[INK], w[PAPER], w[ATTR], w[ATTRINV])
        expect(got == (0, 7, 0, TM_ATTR_DEFAULT, TM_ATTR_CURSOR),
               "boot: window %d white on black, MODE 0 (got %s)" % (n, got))
    if v:
        show(z, "boot")


def check_keep(z, word, target, v):
    """COLR (target 40) / COLB (target 80), then REKEY."""
    verb(z, word, verbose=v)
    expect(cols(z) == target, "%s: %d columns (got %d)" % (word, target, cols(z)))
    expect(not shows(z, MARK), "%s: KEEPMARK gone - the switch ran" % word)
    expect(style(z, 0) == W0, "%s: window 0 MODE/INK/PAPER kept (got %s, want %s)" % (word, style(z, 0), W0))
    expect(style(z, 1) == W1, "%s: window 1 MODE/INK/PAPER kept (got %s, want %s)" % (word, style(z, 1), W1))
    for n in range(2, 8):
        geometry(z, n, word)
    w0, w1 = win(z, 0), win(z, 1)
    expect(tuple(w0[X:H + 1]) == (0, 0, target, TM_ROWS), "%s: window 0 full screen (got %s)" % (word, list(w0)))
    expect(tuple(w1[X:H + 1]) == (0, 10, 40, 4), "%s: window 1 at WINAT 10 0, WINSIZE 4 40 (got %s)" % (word, list(w1)))
    g, a = cell(z, 0, 0)
    expect(g == ord("w") and a == w0[ATTR], "%s: row 0 'window zero' in window 0's attr (glyph %d attr %d, want %d)" % (word, g, a, w0[ATTR]))
    g, a = cell(z, 10, 0)
    expect(g == ord("w") + 128 and a == w1[ATTR], "%s: row 10 'window one' upper charset in window 1's attr (glyph %d attr %d)" % (word, g, a))
    fill_ok(z, word)
    before = (win(z, 0)[ATTR:], win(z, 1)[ATTR:])
    verb(z, "REKEY", settle=1.5, verbose=v)
    after = (win(z, 0)[ATTR:], win(z, 1)[ATTR:])
    expect(before == after, "%s: kept pairs equal what INK/PAPER resolve to now (kept %s, re-resolved %s)" % (word, before, after))


def check_more(z, v):
    verb(z, "MORE", settle=5.0, dismiss=False)
    pending = more_on_screen(z)
    if v:
        show(z, "MORE")
    if pending:
        dismiss_more(z)
    # the verb's own 40 lines scroll KEEPMARK off, so the width is the proof:
    # the setup forced 80, so 40 now means the final switch ran
    expect(cols(z) == 40, "MORE: 40 columns (got %d)" % cols(z))
    expect(not pending, "MORE: no More... - window 0 kept MODE 2 through the switch")
    expect(style(z, 0)[0] == 2, "MORE: window 0 MODE 2 kept (got %s)" % (style(z, 0),))


def check_same(z, v):
    verb(z, "SAME", verbose=v)
    expect(cols(z) == 40, "SAME: 40 columns (got %d)" % cols(z))
    expect(shows(z, MARK), "SAME: KEEPMARK still on screen - a same-width call clears nothing")
    expect(style(z, 0) == W0, "SAME: window 0 style (got %s)" % (style(z, 0),))


def check_trns(z, v):
    verb(z, "TRNS", verbose=v)
    expect(cols(z) == 40, "TRNS: 40 columns (got %d)" % cols(z))
    expect(not shows(z, MARK), "TRNS: KEEPMARK gone - the switch ran")
    expect(style(z, 0) == (0, 7, 227), "TRNS: window 0 paper 227 kept (got %s)" % (style(z, 0),))
    fill_ok(z, "TRNS")


def check_width(z, word, target, v):
    verb(z, word, verbose=v)
    expect(cols(z) == target, "%s: %d columns (got %d)" % (word, target, cols(z)))
    for n in range(2, 8):
        geometry(z, n, word)


def check_leak(z, v):
    check_width(z, "T80", 80, v)
    verb(z, "LEAK", verbose=v)
    expect(cols(z) == 40, "LEAK: 40 columns (got %d)" % cols(z))
    t = live_text(z)
    expect(b"wid" not in t and b"switching" not in t, "LEAK: the pending fragment was discarded")


def check_wins_cent(z, width_verb, target, v):
    """WINAT/WINSIZE/CENTRE on the records win_regeom rewrote. Glyphs are
    compared with & 127: window 1 may still carry COLR's MODE 1."""
    check_width(z, width_verb, target, v)
    verb(z, "WINS", settle=3.0, verbose=v)
    w1 = win(z, 1)
    expect(tuple(w1[X:H + 1]) == (2, 2, 36, 10), "WINS at %d: window 1 at 2,2 size 36x10 (got %s)" % (target, list(w1)))
    g, _ = cell(z, 2, 2)
    expect(g & 127 == ord("T"), "WINS at %d: the wrapped message starts at row 2 col 2 (glyph %d)" % (target, g))
    verb(z, "CENT", verbose=v)
    w2 = win(z, 2)
    x = (target - 20) // 2
    expect(tuple(w2[X:H + 1]) == (x, 0, 20, 3), "CENT at %d: window 2 centred at col %d, size 20x3 (got %s)" % (target, x, list(w2)))
    g, _ = cell(z, 0, x)
    expect(g & 127 == ord("C"), "CENT at %d: CENTRED at row 0 col %d (glyph %d)" % (target, x, g))


def run(z, v):
    time.sleep(4.0)                    # boot, PRO 0 prints the verb list
    check_boot(z, v)
    # pass 1 from the 80-column boot: COLR/COLB setups are no-ops,
    # MORE/SAME/TRNS setups are real switches
    check_keep(z, "COLR", 40, v)
    check_more(z, v)
    check_keep(z, "COLB", 80, v)
    check_same(z, v)
    check_trns(z, v)
    check_leak(z, v)
    # pass 2 flips every setup: COLR/COLB real, MORE/SAME/TRNS no-ops
    check_width(z, "T40", 40, v)
    check_keep(z, "COLR", 40, v)
    check_width(z, "T80", 80, v)
    check_more(z, v)
    check_width(z, "T80", 80, v)
    check_keep(z, "COLB", 80, v)
    check_width(z, "T40", 40, v)
    check_same(z, v)
    check_width(z, "T80", 80, v)
    check_trns(z, v)
    # existing geometry verbs straight after a keep-path switch, both widths
    check_wins_cent(z, "T80", 80, v)
    check_wins_cent(z, "T40", 40, v)
    print("txt40_dump: PASS (boot, two verb orders, leak, WINS/CENT)")


def walk(z, words, shots=None):
    time.sleep(4.0)
    show(z, "boot")
    for i, w in enumerate(words, 1):
        verb(z, w, settle=5.0 if w.upper() == "MORE" else 2.5, dismiss=False, verbose=True)
        if shots:
            bmp = pathlib.Path(shots).resolve() / ("%02d-%s.bmp" % (i, w.upper()))
            bmp.parent.mkdir(parents=True, exist_ok=True)
            z.cmd("save-screen %s" % bmp)       # full composited frame (ZRCP)
            print("   [frame saved to %s]" % bmp)
        if more_on_screen(z):
            print("   [More... pending - dismissing]")
            dismiss_more(z)


def port_free(port):
    s = socket.socket()
    try:
        s.connect(("127.0.0.1", port))
    except OSError:
        return True
    finally:
        s.close()
    return False


def launch(work, port, leg):
    sd = pathlib.Path(work).resolve() / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    shutil.copytree(leg, sd)
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
            sys.exit("txt40_dump: ZEsarUX exited before ZRCP came up")
        try:
            z = zrcp.Zrcp(port=port)
            break
        except OSError:
            time.sleep(0.5)
    if z is None:
        proc.kill()
        sys.exit("txt40_dump: ZRCP never answered on port %d" % port)
    z.cmd("smartload %s" % (sd / "nextdaad.nex"), deadline=60.0)
    return proc, z


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=10019)
    ap.add_argument("--work", default=None)
    ap.add_argument("--leg", default=str(LEG), help="card folder to boot (default sd\\TXT40)")
    ap.add_argument("--walk", default=None, help="comma-separated verbs: print screens, no checks")
    ap.add_argument("--shots", default=None, help="with --walk: save a BMP frame per verb into this folder")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    leg = pathlib.Path(a.leg)
    if not leg.is_dir():
        sys.exit("txt40_dump: %s missing - run tests\\build-tests.ps1 -Txt40" % leg)
    if not port_free(a.port):
        sys.exit("txt40_dump: port %d busy" % a.port)
    work = a.work or str(ROOT / "tests" / "out" / "txt40-run")
    proc, z = launch(work, a.port, leg)
    try:
        if a.walk:
            walk(z, [w.strip() for w in a.walk.split(",") if w.strip()], a.shots)
        else:
            run(z, a.verbose)
    finally:
        try:
            z.close()
        except Exception:
            pass
        proc.kill()
        proc.wait()


if __name__ == "__main__":
    main()
