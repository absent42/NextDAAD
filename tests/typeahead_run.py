# Typeahead regression on the keystroke lab (sd\KBLOG): keys pressed while
# a response runs reach the next prompt; taps and rollover are kept; a key
# that dismisses ANYKEY, More or GETKEY is not typed.
#   .\build.ps1 ; pwsh -File tests\build-tests.ps1 -KbLog ; python tests\typeahead_run.py
import pathlib
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import nleg                                          # noqa: E402
import tilemap                                       # noqa: E402
import zrcp                                          # noqa: E402

ZESARUX = pathlib.Path(r"D:\ZXNextDev\ZEsarUX\zesarux.exe")
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
LEG = ROOT / "sd" / "KBLOG"
PORT = 10044
LAB = "You are in the keystroke lab."
# set-ui-io-ports: rows 0-7 then the joystick byte; a 0 bit is a pressed
# key; bit 0 of a row does not take (zrcp.py), so no ENTER/SPACE/P here.
HOLD_L = "FFFFFFFFFFFFFDFF00"      # row 6 bit 1 = L
HOLD_O = "FFFFFFFFFFFDFFFF00"      # row 5 bit 1 = O
HOLD_OK = "FFFFFFFFFFFDFBFF00"     # O held, K (row 6 bit 2) added
FAILS = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else " - " + detail))
    if not ok:
        FAILS.append(name)


def launch():
    if nleg.port_already_listening(PORT):
        sys.exit("typeahead_run: port %d already listening - a stale emulator?" % PORT)
    work = ROOT / "tests" / "out" / ("typeahead-run-%d" % PORT)
    sd = work / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    shutil.copytree(LEG, sd)
    shutil.copyfile(NEX, sd / "nextdaad.nex")
    proc = subprocess.Popen([
        str(ZESARUX), "--machine", "tbblue", "--realvideo",
        "--enable-esxdos-handler", "--esxdos-root-dir", str(sd),
        "--vo", "null", "--ao", "null",
        "--enable-remoteprotocol", "--remoteprotocol-port", str(PORT),
        "--smartloadpath", str(sd),
    ], cwd=str(sd))
    z = None
    try:
        for _ in range(60):
            if proc.poll() is not None:
                sys.exit("typeahead_run: ZEsarUX exited before ZRCP came up")
            try:
                z = zrcp.Zrcp(port=PORT)
                break
            except OSError:
                time.sleep(0.5)
        if z is None:
            sys.exit("typeahead_run: ZRCP never answered on port %d" % PORT)
        z.cmd("smartload %s" % (sd / "nextdaad.nex"), deadline=60.0)
    except BaseException:
        if z is not None:
            z.close()
        proc.kill()
        proc.wait()
        raise
    return proc, z


def screen(z):
    rows, _ = tilemap.decode(z.read_memory(nleg.TM_MAP, tilemap.GRID_BYTES))
    return rows


_SYM = {}


def sym(name):
    """Address of a resident label from the sjasmplus map (build DEBUG or
    Release first; the map is rewritten by every build)."""
    if name not in _SYM:
        for line in MAP.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.split()
            if len(parts) == 4 and parts[3] == name:
                _SYM[name] = int(parts[0], 16)
                break
        else:
            sys.exit("typeahead_run: %s not in %s - run build.ps1 first" % (name, MAP))
    return _SYM[name]


def frames(z):
    b = z.read_memory(sym("FRAMECOUNTER"), 2)
    return b[0] | (b[1] << 8)


def bottom(rows):
    nb = [r.rstrip() for r in rows if r.strip()]
    return nb[-1] if nb else ""


def _echo_index(rows):
    """Index of the newest prompt row that has text after its '>' (the
    bare new prompt below it is skipped), or -1."""
    for k in range(len(rows) - 1, -1, -1):
        t = rows[k].rstrip()
        if t.startswith(">") and len(t) > 1:
            return k
    return -1


def last_echo(rows):
    k = _echo_index(rows)
    return rows[k].rstrip() if k >= 0 else ""


def echo_reply(rows):
    """The first non-blank row below the newest echo: the game's reply to
    it. Read here, not counted over the screen, because a 20-line response
    scrolls earlier replies off the 32-row screen."""
    k = _echo_index(rows)
    for r in rows[k + 1:] if k >= 0 else []:
        if r.strip():
            return r.rstrip()
    return ""


def tap(z, rows, hold, gap):
    """Headless ZEsarUX runs a frame in about 37 ms of wall time; hold and
    gap must each span one frame edge for the press to be an edge of its
    own. A 50 ms gap is only 13 ms over a frame, so a heavily loaded host
    can merge two taps into one press - that shows as a FAIL, not as
    INCONCLUSIVE; re-run on a quiet host before reading it as a defect."""
    z.hold_matrix(rows)
    time.sleep(hold)
    z.release_matrix()
    time.sleep(gap)


def main():
    if not LEG.is_dir():
        sys.exit("typeahead_run: %s missing - run tests\\build-tests.ps1 -KbLog" % LEG)
    proc = z = None
    try:
        proc, z = launch()
        time.sleep(6.0)
        rows = screen(z)
        check("boot: lab text and a bare prompt",
              any(LAB in r for r in rows) and any(r.rstrip() == ">" for r in rows),
              "\n".join(r for r in rows if r.strip()))

        # 1. typed early: LOOK and ENTER land inside LONG's 2.5 s pause
        z.send_keys("long")
        z.enter(wait=0.3)
        z.send_keys("look")
        z.enter(wait=6.0)
        rows = screen(z)
        check("early: LOOK typed inside the pause is received",
              last_echo(rows) == ">look" and echo_reply(rows) == LAB,
              "echo %r, reply %r" % (last_echo(rows), echo_reply(rows)))

        # 2. typed late: after the prompt is back (the unchanged case)
        z.send_keys("long")
        z.enter(wait=6.0)
        z.send_keys("look")
        z.enter(wait=2.0)
        rows = screen(z)
        check("late: LOOK typed at the prompt is received",
              last_echo(rows) == ">look" and echo_reply(rows) == LAB,
              "echo %r, reply %r" % (last_echo(rows), echo_reply(rows)))

        # 3. ten brief taps of L at the prompt: 50 ms always spans one
        #    emulated frame edge (frames are 25-40 ms of wall time headless)
        for _ in range(10):
            tap(z, HOLD_L, 0.05, 0.15)
        z.enter(wait=1.5)
        rows = screen(z)
        check("tap: ten one-frame taps echo ten l", last_echo(rows) == ">" + "l" * 10,
              "echo %r" % last_echo(rows))

        # 4. rollover: K pressed and released while O is held (O's row is
        #    scanned first, so a first-key scan never sees K)
        z.hold_matrix(HOLD_O)
        time.sleep(0.15)
        z.hold_matrix(HOLD_OK)
        time.sleep(0.15)
        z.hold_matrix(HOLD_O)
        time.sleep(0.15)
        z.release_matrix()
        time.sleep(0.2)
        z.enter(wait=1.5)
        rows = screen(z)
        check("rollover: K under a held O echoes ok", last_echo(rows) == ">ok",
              "echo %r" % last_echo(rows))

        # 5. the key that dismisses ANYKEY is not typed
        z.send_keys("anyk")
        z.enter(wait=1.5)
        rows = screen(z)
        check("anyk: Press any key. shown", any("Press any key." in r for r in rows))
        z.send_keys("l")
        time.sleep(1.0)
        z.send_keys("ook")
        z.enter(wait=1.5)
        rows = screen(z)
        check("anyk: dismiss key is not typed", last_echo(rows) == ">ook", "echo %r" % last_echo(rows))

        # 6. the key that dismisses More... is not typed
        z.send_keys("morex")
        z.enter(wait=3.0)
        rows = screen(z)
        check("morex: More... shown", any("More..." in r for r in rows))
        z.send_keys("l")
        time.sleep(2.5)
        z.send_keys("ook")
        z.enter(wait=1.5)
        rows = screen(z)
        check("morex: dismiss key is not typed", last_echo(rows) == ">ook", "echo %r" % last_echo(rows))

        # 7. the key GETKEY consumed is printed as its code and not typed
        z.send_keys("getk")
        z.enter(wait=1.5)
        z.send_keys("l")
        time.sleep(1.0)
        rows = screen(z)
        check("getk: key code 108 printed", any(r.strip() == "108" for r in rows))
        z.send_keys("ook")
        z.enter(wait=1.5)
        rows = screen(z)
        check("getk: consumed key is not typed", last_echo(rows) == ">ook", "echo %r" % last_echo(rows))
    finally:
        if z is not None:
            try:
                z.close()
            except Exception:
                pass
        if proc is not None:
            proc.kill()
            proc.wait()
    if FAILS:
        sys.exit("typeahead_run: %d check(s) failed: %s" % (len(FAILS), ", ".join(FAILS)))
    print("typeahead_run: all checks passed")


if __name__ == "__main__":
    main()
