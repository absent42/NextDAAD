r"""Boot a staged NextDAAD leg headless in ZEsarUX, type verbs, dump the
tilemap. Usage:
  python tests\xbn\tickcheck.py sd\XBN XTCK [XT40 ...] [--wait 3] [--row 27]
    [--compare R0,C0:R1,C1:H,W] [--glyph R,C]
Prints each non-blank row as rr|text after the last verb; --row N also
prints that row's attribute bytes. Exit 0 on a clean run, 3 if any
--compare block mismatches.

Refuses ticker verbs when the staged GAME.XBN is the xbntest.asm fixture
(tests\out\xbn\GAME.XBN): there fns 34-38 are the fixture's own probes,
and fn 36 (XTCO's EXTERN 1 36) is the getdate probe that derails ZEsarUX.
"""
import argparse, pathlib, shutil, subprocess, sys, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import zrcp, tilemap, nleg  # noqa: E402

ZESARUX = pathlib.Path(r"D:\ZXNextDev\ZEsarUX\zesarux.exe")
PORT = 10031
TM_MAP = 0x6000
FIXTURE_XBN = ROOT / "tests" / "out" / "xbn" / "GAME.XBN"
TICKER_VERBS = {"XTCK", "XT40", "XTPS", "XTPR", "XTBD", "XTNR", "XTLA",
                "XTCO", "XTCD", "XTC0", "XTMQ", "XTML", "XTMX", "XTMW",
                "XTEF"}


def refuse_fixture(leg, verbs):
    staged = leg / "GAME.XBN"
    if not (staged.exists() and FIXTURE_XBN.exists()):
        return
    if staged.read_bytes() != FIXTURE_XBN.read_bytes():
        return
    bad = sorted(v for v in verbs if v.upper() in TICKER_VERBS)
    if bad:
        raise SystemExit("sd leg holds the xbntest.asm FIXTURE, not a ticker "
                         "binary: %s would drive fixture probes (fn 36 derails "
                         "ZEsarUX). Restage with -XbnTicker or -XbnAll." % " ".join(bad))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("leg")
    ap.add_argument("verbs", nargs="+")
    ap.add_argument("--wait", type=float, default=3.0,
                    help="seconds to wait after each verb's ENTER")
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
    args = ap.parse_args()

    leg = (ROOT / args.leg).resolve() if not pathlib.Path(args.leg).is_absolute() else pathlib.Path(args.leg)
    refuse_fixture(leg, args.verbs)
    if nleg.port_already_listening(PORT):
        raise SystemExit("port %d is already taken - a stale ZEsarUX from an "
                         "interrupted run; close it before rerunning" % PORT)
    work = pathlib.Path(tempfile.mkdtemp(prefix="tickcheck-"))
    sd = work / "sd"
    shutil.copytree(leg, sd)
    shutil.copyfile(ROOT / "build" / "nextdaad.nex", sd / "nextdaad.nex")

    proc = subprocess.Popen([
        str(ZESARUX), "--machine", "tbblue", "--realvideo",
        "--enable-esxdos-handler", "--esxdos-root-dir", str(sd),
        "--vo", "null", "--ao", "null",
        "--enable-remoteprotocol", "--remoteprotocol-port", str(PORT),
        "--smartloadpath", str(sd),
    ], cwd=str(sd))
    rc = 1
    try:
        z = None
        for _ in range(60):
            if proc.poll() is not None:
                raise SystemExit("ZEsarUX died before ZRCP came up")
            try:
                z = zrcp.Zrcp(port=PORT)
                break
            except OSError:
                time.sleep(0.5)
        if z is None:
            raise SystemExit("ZRCP never came up")
        z.cmd("smartload %s" % (sd / "nextdaad.nex"), deadline=30.0)
        time.sleep(6.0)
        for verb in args.verbs:
            z.send_keys(verb)
            z.enter(wait=args.wait)
        grid = z.read_memory(TM_MAP, args.cols * tilemap.ROWS * 2)
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
        bad = False
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
        if args.grab:
            src = sd / args.grab
            dst = ROOT / "tests" / "out" / "xbn" / args.grab
            if src.exists():
                shutil.copyfile(src, dst)
                print("grabbed %s -> %s" % (args.grab, dst))
            else:
                print("grab: %s was not written" % args.grab)
        z.close()
        rc = 3 if bad else 0
    finally:
        proc.kill()
        proc.wait(timeout=10)
        shutil.rmtree(work, ignore_errors=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
