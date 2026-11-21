r"""playername module (fns 20-23) on a live interpreter, through the
-XbnAll leg's extern.dsf verbs XNMU/XNMA/XNMK. Each step types a line,
waits for the input editor, then checks the new output rows and the
name bytes in the extern state area (XBN_STATE + 111, 17 bytes).

Usage: python tests\xbn\namecheck.py sd\XBN
The leg is staged by tests\build-tests.ps1 -XbnAll; the check boots it
on CSpect through tests\cspect. Exit 1 on a failed check."""
import argparse, pathlib, shutil, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import xbnrun  # noqa: E402

NAME_ADDR = 0xBF80 + 111        # XBN_STATE + playername's claim
NAME_LEN = 17

# (typed line, second line for the NAME? prompt or None, output marker,
#  expected name bytes up to the NUL, or None to skip the byte check)
STEPS = [
    ("XNMU", None, "NAME NONE", b""),
    ("XNMA", "   kevin   ", "GOT Kevin", b"Kevin"),
    ("XNMU", None, "NAME SET", b"Kevin"),
    ("XNMK", None, "S-PASS R-PASS K-FAIL", b"Kevin"),
    # The state area travels with RAMSAVE/RAMLOAD.
    ("XRMS", None, "", b"Kevin"),
    ("XNMA", "bob", "GOT Bob", b"Bob"),
    ("XRML", None, "", b"Kevin"),
    ("XNMP", None, "NAME=Kevin", b"Kevin"),
    ("XNMA", "abcdefghijklmnopqrstuvwxy", "GOT Abcdefghijklmnop", b"Abcdefghijklmnop"),
    ("XNMA", "   ", "EMPTY", b""),
    ("XNMU", None, "NAME NONE", b""),
    ("XNMA", "", "EMPTY", b""),
]


def tail_rows(s, n=4):
    body = [r.rstrip() for r in s.rows() if r.strip()]
    return "\n".join(body[-n:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("leg")
    args = ap.parse_args()
    leg = (ROOT / args.leg).resolve()
    work, card = xbnrun.stage_card(leg)
    bad = 0
    try:
        with xbnrun.boot(card) as s:
            xbnrun.wait_ready(s)
            xbnrun.disarm_input_timeout(s)
            for verb, answer, marker, name in STEPS:
                xbnrun.submit(s, verb)
                if answer is not None:
                    xbnrun.submit(s, answer)
                shown = tail_rows(s)
                raw = s.read(NAME_ADDR, NAME_LEN)
                stored = raw.split(b"\0", 1)[0]
                ok = marker in shown and (name is None or stored == name)
                print("%s %-5s %-28r -> %r name=%r" % ("PASS" if ok else "FAIL", verb,
                      answer, marker, stored))
                if not ok:
                    print("  screen tail:\n    " + shown.replace("\n", "\n    "))
                    bad += 1
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("%d step(s), %d failed" % (len(STEPS), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
