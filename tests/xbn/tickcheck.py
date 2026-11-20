r"""Boot a staged NextDAAD leg on CSpect (tests\cspect), type verbs, dump the
tilemap. Usage:
  python tests\xbn\tickcheck.py sd\XBN XTCK [XT40 ...] [--wait 3] [--row 27]
    [--compare R0,C0:R1,C1:H,W] [--glyph R,C] [--attr-uniform 27]
Prints each non-blank row as rr|text after the last verb; --row N also
prints that row's attribute bytes; --wait is emulated seconds (50 frames
each) after each verb's ENTER. --attr-uniform N checks row N's attribute
bytes are one nonzero value (XTCO). Exit 0 on a clean run, 3 if any
--compare block or --attr-uniform row fails.

Refuses ticker verbs when the staged GAME.XBN is the xbntest.asm fixture
(tests\out\xbn\GAME.XBN): there fns 34-38 are the fixture's own probes.
"""
import argparse, pathlib, shutil, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "parser"))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import tilemap, xbnrun  # noqa: E402

FRAMES_PER_S = 50
FIXTURE_XBN = ROOT / "tests" / "out" / "xbn" / "GAME.XBN"
TICKER_VERBS = {"XTCK", "XT40", "XTPS", "XTPR", "XTBD", "XTNR", "XTLA",
                "XTCO", "XTCD", "XTC0", "XTMQ", "XTML", "XTMX", "XTMW",
                "XTEF", "XTTY", "XTTW", "XTTO", "XTTA", "XTTB", "XTTC",
                "XTTM", "XTTK", "XTTL"}


def refuse_fixture(leg, verbs):
    staged = leg / "GAME.XBN"
    if not (staged.exists() and FIXTURE_XBN.exists()):
        return
    if staged.read_bytes() != FIXTURE_XBN.read_bytes():
        return
    bad = sorted(v for v in verbs if v.upper() in TICKER_VERBS)
    if bad:
        raise SystemExit("sd leg holds the xbntest.asm FIXTURE, not a ticker "
                         "binary: %s would drive fixture probes. Restage with "
                         "-XbnTicker or -XbnAll." % " ".join(bad))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("leg")
    ap.add_argument("verbs", nargs="+")
    ap.add_argument("--wait", type=float, default=3.0,
                    help="emulated seconds to wait after each verb's ENTER")
    ap.add_argument("--row", type=int, default=None)
    ap.add_argument("--cols", type=int, default=80,
                    help="decode width: 80 or 40 (after GFX 1 18)")
    ap.add_argument("--grab", default=None,
                    help="file in the leg's card root to copy to tests\\out\\xbn after the run")
    ap.add_argument("--compare", action="append", default=[],
                    help="R0,C0:R1,C1:H,W - the HxW block at R0,C0 must equal "
                         "the block at R1,C1 (glyph and attribute); exit 3 if not")
    ap.add_argument("--glyph", action="append", default=[],
                    help="R,C - print the glyph byte at row R, column C")
    ap.add_argument("--attr-uniform", type=int, action="append", default=[],
                    help="N - row N's attribute bytes must be one nonzero value; exit 3 if not")
    args = ap.parse_args()

    leg = (ROOT / args.leg).resolve() if not pathlib.Path(args.leg).is_absolute() else pathlib.Path(args.leg)
    refuse_fixture(leg, args.verbs)
    work, card = xbnrun.stage_card(leg)
    wait_frames = max(1, round(args.wait * FRAMES_PER_S))
    bad = False
    try:
        with xbnrun.boot(card) as s:
            xbnrun.wait_ready(s)
            xbnrun.disarm_input_timeout(s)
            for verb in args.verbs:
                s.type_text(verb)
                s.wait_frames(2, xbnrun.FRAME_TIMEOUT_S)
                s.enter()
                s.wait_frames(wait_frames, max(xbnrun.FRAME_TIMEOUT_S, args.wait * 20))
                xbnrun.wait_ready(s)
            grid = s.read(xbnrun.TM_MAP, args.cols * tilemap.ROWS * 2)
            rows, attrs = tilemap.decode(grid, cols=args.cols)
            for i, r in enumerate(rows):
                if r.strip():
                    print("%02d|%s" % (i, r.rstrip()))
            if args.row is not None:
                print("attr %02d|%s" % (args.row, " ".join("%02X" % a for a in attrs[args.row])))

            def cell(r, c):
                i = (r * args.cols + c) * 2
                return grid[i], grid[i + 1]
            for spec in args.glyph:
                r, c = (int(v) for v in spec.split(","))
                print("glyph %d,%d = $%02X" % (r, c, cell(r, c)[0]))
            for spec in args.compare:
                a, b, hw = spec.split(":")
                r0, c0 = (int(v) for v in a.split(","))
                r1, c1 = (int(v) for v in b.split(","))
                h, w = (int(v) for v in hw.split(","))
                miss = []
                for dr in range(h):
                    for dc in range(w):
                        x, y = cell(r0 + dr, c0 + dc), cell(r1 + dr, c1 + dc)
                        if x != y:
                            miss.append("+%d,+%d: $%02X/$%02X vs $%02X/$%02X"
                                        % (dr, dc, x[0], x[1], y[0], y[1]))
                if miss:
                    bad = True
                    print("compare %s MISMATCH (%d cells)" % (spec, len(miss)))
                    for m in miss[:20]:
                        print("  " + m)
                else:
                    print("compare %s OK" % spec)
            for n in args.attr_uniform:
                vals = sorted(set(attrs[n]))
                ok = len(vals) == 1 and vals[0] != 0
                bad |= not ok
                print("%s attr row %d: %s" % ("PASS" if ok else "FAIL", n,
                      " ".join("$%02X" % v for v in vals)))
            if args.grab:
                src = card / args.grab
                dst = ROOT / "tests" / "out" / "xbn" / args.grab
                if src.exists():
                    shutil.copyfile(src, dst)
                    print("grabbed %s -> %s" % (args.grab, dst))
                else:
                    print("grab: %s was not written" % args.grab)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 3 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
