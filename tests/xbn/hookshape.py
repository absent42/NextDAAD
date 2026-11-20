r"""Single-hook format 3 headers on a live interpreter. No shipped
binary has a format 3 header with one hook entry 0; this boots two,
built by EXTERNS.BAT's builder from tests\xbn\usermods: ua (lineEntry
set, outEntry 0) and uo (lineEntry 0, outEntry set). ua's line hook
counts typed lines in flag 190, uo's output hook counts printed
characters in flag 191.

Usage: python tests\xbn\hookshape.py sd\XBN
The leg is the staged XBN leg (tests\build-tests.ps1 -Xbn); its
GAME.XBN is swapped in a temp copy. Each module boots on CSpect through
tests\cspect. Exit 1 on a failed check."""
import argparse, pathlib, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import xbnrun  # noqa: E402

LINE_FLAG = 190         # OUT_FLAG = 191 is read as the next byte
VERB = "XYZZY"          # unknown to extern.dsf: one line in, a message out


def build(module, out):
    subprocess.run([
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        str(ROOT / "authoring-kit" / "lib" / "xbnbuild.ps1"),
        str(ROOT / "tests" / "xbn" / "usermods" / module),
        "-Out", str(out),
        "-SjasmPlus", str(ROOT / "tools" / "sjasmplus" / "sjasmplus.exe"),
    ], check=True)


def turn(leg, xbn):
    """Boot the leg with xbn as GAME.XBN and type VERB once. Returns the
    (line, out) counter deltas across that turn."""
    work, card = xbnrun.stage_card(leg, xbn)
    try:
        with xbnrun.boot(card) as s:
            flags = s.sym("FLAGS") + LINE_FLAG
            xbnrun.wait_ready(s)
            xbnrun.disarm_input_timeout(s)
            before = s.read(flags, 2)
            xbnrun.submit(s, VERB)
            after = s.read(flags, 2)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return ((after[0] - before[0]) & 0xFF, (after[1] - before[1]) & 0xFF)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("leg")
    args = ap.parse_args()
    leg = (ROOT / args.leg).resolve()
    out = ROOT / "tests" / "out" / "xbn"
    out.mkdir(parents=True, exist_ok=True)
    bad = 0
    for module in ("ua", "uo"):
        xbn = out / ("hookshape-%s.XBN" % module)
        build(module, xbn)
        line, printed = turn(leg, xbn)
        if module == "ua":
            ok = line == 1 and printed == 0     # one line hook call, no out hook
        else:
            ok = line == 0 and printed != 0     # out hook counted, no line hook
        print("%s %s line+%d out+%d" % ("PASS" if ok else "FAIL", module, line, printed))
        bad += not ok
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
