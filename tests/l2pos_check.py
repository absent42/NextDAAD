r"""Drives tests\l2pos.dsf on CSpect (tests\cspect) and byte-compares the front Layer 2 surface
after every walk step with tests\art\mkl2pos.py's expect_<id>.bin. The scroll steps also compare
tilemap rows 0-27 with tests\l2pos_tm\tm_<id>.bin; --capture writes those files instead.

Run from the repo root, after
    .\build.ps1                                   (the map must match the NEX)
    pwsh -File tests\build-tests.ps1 -L2Pos       (or -L2PosWide, -GfxZx0)

    python tests\l2pos_check.py [--mode 1] [--port N] [--work DIR] [--capture]

--port is the harness MCP port (tests\cspect\launcher.py PORT_RANGE, default the first free).
Exit 0 if every step passes, 1 on any FAIL or timeout. The surface is read with the CPU
paused; the emulator runs on a scratch copy of the staged leg and is closed on every exit."""
import argparse
import json
import pathlib
import shutil
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from cspect import Session                             # noqa: E402
from cspect.client import CSpectError                  # noqa: E402

LEG = ROOT / "sd" / "L2POS"
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
ART = {0: ROOT / "tests" / "out" / "l2pos-art", 1: ROOT / "tests" / "out" / "l2pos-art-wide"}
TM_DIR = ROOT / "tests" / "l2pos_tm"
TM_ROWS = 28                       # rows above text window 0
TM_STRIDE = 160                    # 80 columns x (glyph, attribute)

TEXT_ROWS = range(28, 32)          # l2pos.dsf window 0
FSTEP = 100                        # l2pos.dsf flag fStep
PAGE_SIZE = 8192

BOOT_TIMEOUT = 60.0                # step 1 runs in PRO 1 at boot
STEP_TIMEOUT = 30.0                # whole step, all presses included
REPRESS_AFTER_FRAMES = 200         # no new step text by then = key dropped
MAX_PRESSES = 3
HOLD_FRAMES = 3                    # wait_key wants a press then a release
POLL_S = 0.05


class Timeout(Exception):
    pass


def launch(work, port):
    """A Session on a scratch copy of the leg with the built .nex."""
    sd = pathlib.Path(work).resolve() / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    shutil.copytree(LEG, sd)
    shutil.copyfile(NEX, sd / "nextdaad.nex")
    return Session.boot(sd, sd / "nextdaad.nex", MAP, port=port)


def read_surface(s, front, mode):
    """The front surface: 16K bank front's pages, 6 (256x192) or 10 (320x256)."""
    npages = 10 if mode else 6
    return b"".join(s.read_page(front * 2 + p, 0, PAGE_SIZE) for p in range(npages))


def flag(s, n):
    return s.read(s.sym("FLAGS") + n, 1)[0]


def text_rows(s):
    rows = s.rows()
    return [rows[r] for r in TEXT_ROWS]


def press(s):
    s.press("SYM", frames=HOLD_FRAMES)


def wait_step(s, step, want_flag, first):
    """Wait until the step printed its text + "RAN" and flag 100 holds
    want_flag. A press whose step text never appears is re-sent."""
    started = step["text"].rstrip()
    done = step["text"] + "RAN"
    presses = 0 if first else 1
    t0 = time.monotonic()
    last_press = s.frame()
    limit = BOOT_TIMEOUT if first else STEP_TIMEOUT
    while True:
        rows = text_rows(s)
        if any("PICTURE FAILED" in r for r in rows):
            raise Timeout("step %s printed PICTURE FAILED" % step["id"])
        f = flag(s, FSTEP)
        if any(done in r for r in rows) and f == want_flag:
            return presses
        if f > want_flag:
            raise Timeout("step %s: flag %d is %d, expected %d (a press ran twice)"
                          % (step["id"], FSTEP, f, want_flag))
        if time.monotonic() - t0 > limit:
            raise Timeout("step %s: no '%s' with flag %d = %d after %.0f s (flag %d, rows %r)"
                          % (step["id"], done, FSTEP, want_flag, limit, f, rows))
        if (not first and (s.frame() - last_press) & 0xFFFF > REPRESS_AFTER_FRAMES
                and not any(started in r for r in rows)):
            if presses >= MAX_PRESSES:
                raise Timeout("step %s: %d presses, step never started" % (step["id"], presses))
            press(s)
            presses += 1
            last_press = s.frame()
        time.sleep(POLL_S)


def check_tm(step, tm, capture):
    path = TM_DIR / step["tm"]
    if capture:
        TM_DIR.mkdir(exist_ok=True)
        path.write_bytes(tm)
        print("step %s tilemap captured to %s" % (step["id"], path))
        return True
    want = path.read_bytes()
    if tm == want:
        print("step %s tilemap PASS" % step["id"])
        return True
    i = next(k for k in range(len(want)) if tm[k] != want[k])
    print("step %s tilemap FAIL first mismatch at row %d col %d byte %d got %d want %d"
          % (step["id"], i // TM_STRIDE, (i % TM_STRIDE) // 2, i % 2, tm[i], want[i]))
    return False


def check_step(s, step, artdir, capture=False):
    mode = step["mode"]
    want = (artdir / step["expect"]).read_bytes()
    tm = None
    s.pause()
    try:
        front = s.read(s.sym("L2FRONTBANK"), 1)[0]
        got = read_surface(s, front, mode)
        if step.get("tm"):
            tm = s.read(s.sym("TM_MAP"), TM_ROWS * TM_STRIDE)
    finally:
        s.resume()
    if tm is not None and not check_tm(step, tm, capture):
        return False
    if len(got) != len(want):
        print("step %s FAIL read %d bytes, expect file has %d" % (step["id"], len(got), len(want)))
        return False
    if got == want:
        print("step %s PASS" % step["id"])
        return True
    diff = [k for k in range(len(want)) if got[k] != want[k]]
    i = diff[0]
    x, y = (i // 256, i % 256) if mode else (i % 256, i // 256)
    print("step %s FAIL first mismatch at x=%d y=%d got %d want %d (%d bytes differ, front bank %d)"
          % (step["id"], x, y, got[i], want[i], len(diff), front))
    return False


def check_leg(mode, artdir, walk):
    """The staged leg must be this mode's set and the current build."""
    plain = "001.NX2" if mode else "001.NXI"
    if not ((LEG / plain).exists() or (LEG / (plain + ".ZX0")).exists()):
        sys.exit("l2pos_check: %s has no %s - stage -L2Pos%s" % (LEG, plain, "Wide" if mode else ""))
    if walk["set_mode"] != mode:
        sys.exit("l2pos_check: %s is the mode %d walk" % (artdir, walk["set_mode"]))
    staged = LEG / "NEXTDAAD.NEX"
    if staged.read_bytes() != NEX.read_bytes():
        sys.exit("l2pos_check: %s differs from %s - restage after the build" % (staged, NEX))
    for name in walk["plain"] + walk["nx3"]:
        if (LEG / name).exists() and (LEG / name).read_bytes() != (artdir / name).read_bytes():
            sys.exit("l2pos_check: staged %s is not %s's" % (name, artdir))


def run(s, walk, artdir, capture=False):
    ok = True
    for i, step in enumerate(walk["steps"]):
        want_flag = 0 if step["fstep"] is None else step["fstep"] + 1
        if i:
            press(s)
        n = wait_step(s, step, want_flag, i == 0)
        if n > 1:
            print("  step %s took %d presses" % (step["id"], n))
        ok &= check_step(s, step, artdir, capture)
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", type=int, choices=(0, 1), default=0)
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--work", default=None, help="scratch card directory")
    ap.add_argument("--capture", action="store_true", help="write the scroll steps' tilemap files")
    a = ap.parse_args()
    if not LEG.is_dir():
        sys.exit("l2pos_check: %s missing - run tests\\build-tests.ps1 -L2Pos" % LEG)
    artdir = ART[a.mode]
    walk = json.loads((artdir / "l2pos_walk.json").read_text(encoding="utf-8"))
    check_leg(a.mode, artdir, walk)
    work = a.work or str(ROOT / "tests" / "out" / "l2pos-run")
    s = None
    try:
        s = launch(work, a.port)
        ok = run(s, walk, artdir, a.capture)
    except (Timeout, TimeoutError, CSpectError, OSError) as e:
        print("l2pos_check: TIMEOUT/ERROR %s" % e)
        ok = False
    finally:
        if s is not None:
            s.close()
    print("l2pos_check: mode %d %s" % (a.mode, "ALL PASS" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
