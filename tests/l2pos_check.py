# Drives tests\l2pos.dsf on ZEsarUX and byte-compares the front Layer 2
# surface after every walk step with tests\art\mkl2pos.py's expect_<id>.bin.
#
# Run from the repo root, after
#     .\build.ps1                                   (the map must match the NEX)
#     pwsh -File tests\build-tests.ps1 -L2Pos       (or -L2PosWide, -GfxZx0)
#
#     python tests\l2pos_check.py [--mode 1] [--port N] [--work DIR]
#
# Exit 0 if every step passes, 1 on any FAIL or timeout. The emulator runs
# on a scratch copy of the staged leg and is killed on every exit path.
import argparse
import json
import pathlib
import shutil
import socket
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import tilemap                                       # noqa: E402
import zrcp                                          # noqa: E402

ZESARUX = pathlib.Path(r"D:\ZXNextDev\ZEsarUX\zesarux.exe")
LEG = ROOT / "sd" / "L2POS"
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
ART = {0: ROOT / "tests" / "out" / "l2pos-art", 1: ROOT / "tests" / "out" / "l2pos-art-wide"}

TM_MAP = 0x6000
TEXT_ROWS = range(28, 32)          # l2pos.dsf window 0
FSTEP = 100                        # l2pos.dsf flag fStep

# Zone 0 = flat Next RAM, 8K page P at (P+32)*8192 (tests/intro/zes_intro.py,
# verified there against a staged NXC); re-verified here by step 1's compare.
ZONE_RAM = 0
PAGE_ZONE_OFFSET = 32
PAGE_SIZE = 8192
# enter-cpu-step is refused about 7% of the time (zes_intro.py freeze()).
CPU_STEP_ATTEMPTS = 20
CPU_STEP_RETRY_S = 0.1

BOOT_TIMEOUT = 60.0                # step 1 runs in PRO 1 at boot
STEP_TIMEOUT = 30.0                # whole step, all presses included
REPRESS_AFTER = 4.0                # no new step text by then = key dropped
MAX_PRESSES = 3
HOLD_FRAMES = 3                    # key held across frameCounter edges


class Timeout(Exception):
    pass


_MAP = {}


def map_symbol(name):
    """CPU address of an UPPERCASE map symbol (cycle_dump.py map_symbol)."""
    if name not in _MAP:
        for line in MAP.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.split()
            if len(parts) == 4 and parts[3] == name:
                _MAP[name] = int(parts[0], 16)
                break
        else:
            sys.exit("l2pos_check: %s not in %s - build first" % (name, MAP))
    return _MAP[name]


def port_free(port):
    s = socket.socket()
    try:
        s.connect(("127.0.0.1", port))
    except OSError:
        return True
    finally:
        s.close()
    return False


def launch(work, port):
    """cycle_dump.py launch(): scratch copy of the leg, .nex via smartload."""
    sd = pathlib.Path(work).resolve() / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    shutil.copytree(LEG, sd)
    shutil.copyfile(NEX, sd / "nextdaad.nex")
    proc = subprocess.Popen([
        str(ZESARUX), "--machine", "tbblue", "--realvideo",
        "--enable-esxdos-handler", "--esxdos-root-dir", str(sd),
        "--vo", "null", "--ao", "null",
        "--enable-remoteprotocol", "--remoteprotocol-port", str(port),
        "--smartloadpath", str(sd),
    ], cwd=str(sd), stdout=subprocess.DEVNULL)
    try:
        z = None
        for _ in range(60):
            if proc.poll() is not None:
                raise Timeout("ZEsarUX exited before ZRCP came up")
            try:
                z = zrcp.Zrcp(port=port)
                break
            except OSError:
                time.sleep(0.5)
        if z is None:
            raise Timeout("ZRCP never answered on port %d" % port)
        z.cmd("smartload %s" % (sd / "nextdaad.nex"), deadline=60.0)
    except BaseException:
        proc.kill()
        proc.wait()
        raise
    return proc, z


def freeze(z):
    """zes_intro.py freeze(): enter-cpu-step, retried until accepted."""
    reply = ""
    for _ in range(CPU_STEP_ATTEMPTS):
        reply = z.enter_cpu_step()
        if not reply.lstrip().lower().startswith("error"):
            return
        time.sleep(CPU_STEP_RETRY_S)
    raise Timeout("enter-cpu-step refused %d times: %r" % (CPU_STEP_ATTEMPTS, reply))


def read_surface(z, front, mode):
    """zes_intro.py read_surface(): the front surface's pages in one zone 0
    read. Leaves zone 0 selected; the caller restores -1."""
    npages = 10 if mode else 6
    z.cmd("set-memory-zone %d" % ZONE_RAM)
    return z.read_memory((front * 2 + PAGE_ZONE_OFFSET) * PAGE_SIZE, npages * PAGE_SIZE)


def flag(z, n):
    return z.read_memory(map_symbol("FLAGS") + n, 1)[0]


def text_rows(z):
    rows, _ = tilemap.decode(z.read_memory(TM_MAP, tilemap.GRID_BYTES))
    return [rows[r] for r in TEXT_ROWS]


def shown(z, s):
    return any(s in r for r in text_rows(z))


def press(z):
    """SYMBOL SHIFT held until frameCounter has moved HOLD_FRAMES times
    (wait_key wants a press then a release), bounded to 3 s."""
    fc = map_symbol("FRAMECOUNTER")
    last = z.read_memory(fc, 1)[0]
    edges, end = 0, time.time() + 3.0
    z.hold_matrix(zrcp.Zrcp.MATRIX_SYM_SHIFT)
    try:
        while edges < HOLD_FRAMES and time.time() < end:
            now = z.read_memory(fc, 1)[0]
            if now != last:
                edges += 1
                last = now
            else:
                time.sleep(0.02)
    finally:
        z.release_matrix()


def wait_step(z, step, want_flag, first):
    """Wait until the step printed its text + "RAN" and flag 100 holds
    want_flag. A press whose step text never appears is re-sent."""
    started = step["text"].rstrip()
    done = step["text"] + "RAN"
    presses = 0 if first else 1
    t0 = last_press = time.time()
    limit = BOOT_TIMEOUT if first else STEP_TIMEOUT
    while True:
        rows = text_rows(z)
        if any("PICTURE FAILED" in r for r in rows):
            raise Timeout("step %s printed PICTURE FAILED" % step["id"])
        f = flag(z, FSTEP)
        if any(done in r for r in rows) and f == want_flag:
            return presses
        if f > want_flag:
            raise Timeout("step %s: flag %d is %d, expected %d (a press ran twice)"
                          % (step["id"], FSTEP, f, want_flag))
        now = time.time()
        if now - t0 > limit:
            raise Timeout("step %s: no '%s' with flag %d = %d after %.0f s (flag %d, rows %r)"
                          % (step["id"], done, FSTEP, want_flag, limit, f, rows))
        if (not first and now - last_press > REPRESS_AFTER
                and not any(started in r for r in rows)):
            if presses >= MAX_PRESSES:
                raise Timeout("step %s: %d presses, step never started" % (step["id"], presses))
            press(z)
            presses += 1
            last_press = time.time()
        time.sleep(0.1)


def check_step(z, step, artdir):
    mode = step["mode"]
    want = (artdir / step["expect"]).read_bytes()
    freeze(z)
    try:
        front = z.read_memory(map_symbol("L2FRONTBANK"), 1)[0]
        got = read_surface(z, front, mode)
    finally:
        z.cmd("set-memory-zone -1")
        z.exit_cpu_step()
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
    for name in [plain] + ["%03d.NXP" % n for n in range(2, 8)]:
        if (LEG / name).exists() and (LEG / name).read_bytes() != (artdir / name).read_bytes():
            sys.exit("l2pos_check: staged %s is not %s's" % (name, artdir))


def run(z, walk, artdir):
    ok = True
    for i, step in enumerate(walk["steps"]):
        want_flag = 0 if step["fstep"] is None else step["fstep"] + 1
        if i:
            press(z)
        n = wait_step(z, step, want_flag, i == 0)
        if n > 1:
            print("  step %s took %d presses" % (step["id"], n))
        ok &= check_step(z, step, artdir)
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", type=int, choices=(0, 1), default=0)
    ap.add_argument("--port", type=int, default=10023)
    ap.add_argument("--work", default=None, help="scratch card directory")
    a = ap.parse_args()
    if not LEG.is_dir():
        sys.exit("l2pos_check: %s missing - run tests\\build-tests.ps1 -L2Pos" % LEG)
    artdir = ART[a.mode]
    walk = json.loads((artdir / "l2pos_walk.json").read_text(encoding="utf-8"))
    check_leg(a.mode, artdir, walk)
    if not port_free(a.port):
        sys.exit("l2pos_check: port %d busy" % a.port)
    work = a.work or str(ROOT / "tests" / "out" / "l2pos-run")
    proc = z = None
    try:
        proc, z = launch(work, a.port)
        ok = run(z, walk, artdir)
    except (Timeout, zrcp.ZrcpError, OSError) as e:
        print("l2pos_check: TIMEOUT/ERROR %s" % e)
        ok = False
    finally:
        if z is not None:
            try:
                z.close()
            except Exception:
                pass
        if proc is not None:
            proc.kill()
            proc.wait()
    print("l2pos_check: mode %d %s" % (a.mode, "ALL PASS" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
