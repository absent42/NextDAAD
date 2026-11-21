r"""BLT303 smoke run on the CSpect harness: the bench runs every row and none is skipped or
fails its check. CSpect's timings are not silicon's: the figures are not used. The log is read
from the bench's RAM buffer: CSpect's esxDOS refuses the bench's open mode, so the file write
(the framework's, proven on silicon by CORE303) is not checked here.

Run from the repo root after tests\core303\blit\build.ps1 -AllowDirty:

    python tests\cspect\blt303_smoke.py [--port N] [--work DIR] [--timeout S]
    python tests\cspect\blt303_smoke.py --log FILE     (judge a kept log, no emulator)

Exit 0 when every row ran with its check OK, 1 otherwise."""
import argparse
import pathlib
import re
import shutil
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "tests" / "core303"))
from cspect import Session                             # noqa: E402
import parse                                           # noqa: E402

OUT = ROOT / "build" / "blt303"
NEX = OUT / "BLT303.NEX"
SYM = OUT / "BLT303.sym"
ROWS = ROOT / "tests" / "core303" / "blit" / "rows.asm"
LOG_PAGE = 82                                          # bench/log.asm


def write_map(path):
    """CSPECTMAP lines from the sjasmplus symbol file: the bench is one bank at $8000."""
    lines = []
    for line in SYM.read_text(encoding="ascii").splitlines():
        m = re.fullmatch(r"(\w+): EQU 0x([0-9A-F]{8})", line)
        if m and 0x8000 <= int(m.group(2), 16) < 0xC000:
            lines.append("%s %s 00 %s" % (m.group(2), m.group(2), m.group(1)))
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def judge(path, want):
    lg = parse.parse_log(path)
    bad = [r.tag for r in lg.rows if r.ck_ok is False]
    got = [r.tag for r in lg.rows]
    for tag, why in lg.skips:
        print("SKIP %s %s" % (tag, why))
    for tag in bad:
        print("BAD  %s" % tag)
    print("%d rows of %d, %d skipped, %d bad" % (len(got), len(want), len(lg.skips), len(bad)))
    return 0 if got == want and not bad else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--work", default=str(ROOT / "tests" / "out" / "blt303_smoke"))
    ap.add_argument("--timeout", type=float, default=900.0)
    ap.add_argument("--log", help="judge this kept log and exit")
    a = ap.parse_args()
    want = re.findall(r'ROW\s+"(\w{4})"', ROWS.read_text(encoding="ascii"))
    if a.log:
        return judge(a.log, want)
    work = pathlib.Path(a.work).resolve()
    sd = work / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    sd.mkdir(parents=True)
    shutil.copyfile(NEX, sd / "BLT303.NEX")
    mp = work / "BLT303.map"
    write_map(mp)
    kept = work / "BLT303.RAM.LOG"

    with Session.boot(sd, sd / "BLT303.NEX", mp, pin_mouse=False, port=a.port) as s:
        w = lambda name: (lambda v: v[0] | v[1] << 8)(s.read(s.sym(name), 2))
        t0 = time.monotonic()
        last = 0
        while True:                                     # main's last instruction is a HALT under DI
            time.sleep(5)
            n = w("rtNum")
            if n != last:
                print("%5.0f s row %d" % (time.monotonic() - t0, n), flush=True)
                last = n
            ended = n == len(want) and \
                s.read(s.sym("logStep"), 1)[0] != 0
            if ended or time.monotonic() - t0 > a.timeout:
                break
        pc = s.pause()
        used = w("logPtr")
        ram = b"".join(s.read_page(LOG_PAGE + k, 0, 0x2000) for k in range((used >> 13) + 1))[:used]
        kept.write_bytes(ram)
        if not ended:
            print("FAIL not finished after %.0f s: row %d of %d, PC $%04X; RAM log kept in %s" % (
                time.monotonic() - t0, last, len(want), pc, kept))
            return 1
    return judge(kept, want)


if __name__ == "__main__":
    sys.exit(main())
