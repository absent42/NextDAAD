r"""Leg 7 fixture smoke run on the CSpect harness: the COPY, PIC and FULL verbs run to their end and
the colour cycle stays armed and stepping across them. The staged leg's files are used with the
current DEBUG build (the cycle snapshot is DEBUG-only). The clip (VID) is not run: silicon only.

Run from the repo root after pwsh -File tests\blit_legs2.ps1 (which leaves the build DEBUG):

    python tests\cspect\blt7_smoke.py [--port N] [--work DIR]

Exit 0 on pass, 1 otherwise."""
import argparse
import pathlib
import shutil
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from cspect import Session                             # noqa: E402
import cycle_dump as cd                                # noqa: E402

LEG = ROOT / "sd" / "LEGBLT7"
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
PROMPT = "S15 video"
BURST_WAIT_S = 120.0


def verb(s, word, text, deadline=cd.STEP_WAIT_S):
    """Type a verb; seconds until its message is on the bottom-most printed row."""
    before = sum(text in r for r in s.rows())
    s.type_text(word)
    s.enter()
    t0 = time.monotonic()
    s.wait_until(lambda: sum(text in r for r in s.rows()) > before, deadline, cd.POLL_S, repr(text))
    return time.monotonic() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--work", default=str(ROOT / "tests" / "out" / "blt7_smoke"))
    a = ap.parse_args()
    sd = pathlib.Path(a.work).resolve() / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    shutil.copytree(LEG, sd)
    shutil.copyfile(NEX, sd / "NEXTDAAD.NEX")

    with Session.boot(sd, sd / "NEXTDAAD.NEX", MAP, port=a.port) as s:
        cd.wait_text(s, "S1 cycling", cd.STEP_WAIT_S)
        for _ in range(40):                              # the scripted walk: one key per step
            if any(PROMPT in r for r in s.rows()):
                break
            s.press(cd.DISMISS_KEY, frames=cd.DISMISS_HOLD_FRAMES)
            time.sleep(2.0)
        else:
            print("FAIL the walk never reached the prompt")
            return 1
        s.wait_frames(30, cd.FRAME_WAIT_S)
        ok = True
        print("SPR  %.1f s" % verb(s, "SPR", "S19 sprite set 2 started"))
        for word, text in (("COPY", "COPY done"), ("PIC", "PIC done"), ("FULL", "FULL done")):
            st0 = cd.State(s)
            f0 = s.frame()
            took = verb(s, word, text, BURST_WAIT_S)
            st1 = cd.State(s)
            frames = (s.frame() - f0) & 0xFFFF
            stepped = (st1.steps - st0.steps) & 0xFFFF
            want = frames // st1.frames
            good = st1.armed and abs(stepped - want) <= 2
            ok = ok and good
            print("%-4s %.1f s, %d frames, cycle steps %d (frames/%d = %d), armed %d: %s" % (
                word, took, frames, stepped, st1.frames, want, bool(st1.armed), "ok" if good else "BAD"))
        print("SPR  %.1f s (second upload, after the draws)" % verb(s, "SPR", "S19 sprite set 2 started"))
        s.type_text("STOPC")
        s.enter()
        s.wait_frames(30, cd.FRAME_WAIT_S)
        if cd.State(s).armed:
            print("BAD  STOPC left the cycle armed")
            ok = False
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
