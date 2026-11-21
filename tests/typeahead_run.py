r"""Typeahead regression on the keystroke lab (sd\KBLOG) under CSpect (tests\cspect): keys
typed during a response reach the prompt; taps and rollover kept; dismiss keys not typed.
  .\build.ps1 ; pwsh -File tests\build-tests.ps1 -KbLog ; python tests\typeahead_run.py
Holds are press_keys frame counts; waits poll the lock bytes, the screen and FRAMECOUNTER.
Exit 1 on a failed check, 2 if a check was inconclusive."""
import pathlib
import shutil
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from cspect import Session                           # noqa: E402
from cspect.client import CHUNK, Mcp                 # noqa: E402

NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
LEG = ROOT / "sd" / "KBLOG"
WORK = ROOT / "tests" / "out" / "typeahead-run"
LAB = "You are in the keystroke lab."
PAUSE_FRAMES = 125           # LONG's PAUSE as compiled (tests\build-tests.ps1 asserts 35 125 22)
HELD_AFTER_PROMPT = 15       # 4b: well inside kb_char's 35-frame first repeat
TAP_FRAMES = 1
ROLL_FRAMES = 8              # per rollover step: three steps stay inside the 35-frame repeat
ROLLOVER = "O O+K O"         # gap 0: O stays down while K goes down and up
DOUBLE_TAP_FRAMES = 3
L_ROW, L_BIT = 0xBFFE, 0x02  # ENTER L K J H: L is bit 1
READY_CONFIRM_FRAMES = 5     # (moreLock, wrapLock) = (1, 1) also holds while SM32 prints
WAIT_S = 30.0
POLL_S = 0.005
FAILS = []
INCONCLUSIVE = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else " - " + detail), flush=True)
    if not ok:
        FAILS.append(name)


def inconclusive(name, detail):
    print("INCONCLUSIVE " + name + " - " + detail, flush=True)
    INCONCLUSIVE.append(name)


def stage():
    sd = WORK / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    shutil.copytree(LEG, sd)
    shutil.copyfile(NEX, sd / "nextdaad.nex")
    return sd


def key_session(s):
    """A second MCP session on s's CSpect: press_keys blocks it while s samples."""
    m = Mcp(s.mcp.port)
    m.initialize()
    return Session(m, s.symbols, map_file=s.map_file)


def locks(s):
    """(moreLock, wrapLock) from one read when both fit one chunk."""
    a, b = s.sym("MORELOCK"), s.sym("WRAPLOCK")
    lo = min(a, b)
    if abs(a - b) < CHUNK:
        span = s.read(lo, abs(a - b) + 1)
        return span[a - lo] != 0, span[b - lo] != 0
    return s.read(a, 1)[0] != 0, s.read(b, 1)[0] != 0


def queue_empty(s):
    q = s.read(s.sym("KBQW"), 1)[0], s.read(s.sym("KBQR"), 1)[0]
    return q[0] == q[1]


def wait_ready(s):
    """Input editor ready with the typeahead queue drained, confirmed READY_CONFIRM_FRAMES on."""
    def ready():
        if locks(s) != (True, True) or not queue_empty(s):
            return False
        s.wait_frames(READY_CONFIRM_FRAMES, WAIT_S)
        return locks(s) == (True, True)
    s.wait_until(ready, WAIT_S, POLL_S, "the input editor")


def seen(s, pred, timeout=WAIT_S):
    """pred(screen rows) polled until true or timeout; the last value."""
    deadline = time.monotonic() + timeout
    while True:
        ok = pred(s.rows())
        if ok or time.monotonic() >= deadline:
            return ok
        time.sleep(POLL_S)


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


def prompt_away(s):
    return not bottom(s.rows()).startswith(">")


def submit(s, text):
    s.type_text(text + "\n")
    wait_ready(s)


def held_through(s, keys):
    """keys holds L from LONG's last line to HELD_AFTER_PROMPT frames past the pause while s
    watches for the editor. Returns (L down when the editor started, detail)."""
    s.type_text("long\n")
    if not seen(s, lambda rows: bottom(rows).startswith("long 20")):
        sys.exit("typeahead_run: LONG's last line never appeared")
    f0 = s.frame()
    hold = PAUSE_FRAMES + HELD_AFTER_PROMPT - ((s.frame() - f0) & 0xFFFF)
    out = {}

    def play():
        try:
            keys.press("L", frames=hold)
        except BaseException as exc:             # re-raised below
            out["error"] = exc

    t = threading.Thread(target=play, daemon=True)
    t.start()
    try:
        s.wait_until(lambda: locks(s) == (True, True), WAIT_S, POLL_S, "the prompt after LONG (4b)")
        down = not s.port_in(L_ROW) & L_BIT
        f_prompt = s.frame()
    finally:
        t.join()
    if "error" in out:
        raise out["error"]
    f_end = s.frame()
    return down, "hold %d frames, prompt seen %d frames after long 20, press returned %d later" % (
        hold, (f_prompt - f0) & 0xFFFF, (f_end - f_prompt) & 0xFFFF)


def run(s, keys):
    wait_ready(s)
    rows = s.rows()
    check("boot: lab text and a bare prompt",
          any(LAB in r for r in rows) and any(r.rstrip() == ">" for r in rows),
          "\n".join(r for r in rows if r.strip()))

    # 1. typed early: LOOK and ENTER land inside LONG's pause
    s.type_text("long\n")
    s.type_text("look")
    still_paused = prompt_away(s)
    s.enter()
    wait_ready(s)
    rows = s.rows()
    if not still_paused:
        inconclusive("early", "the prompt was back before ENTER - echo %r" % last_echo(rows))
    else:
        check("early: LOOK typed inside the pause is received",
              last_echo(rows) == ">look" and echo_reply(rows) == LAB,
              "echo %r, reply %r" % (last_echo(rows), echo_reply(rows)))

    # 2. typed late: after the prompt is back (the unchanged case)
    submit(s, "long")
    submit(s, "look")
    rows = s.rows()
    check("late: LOOK typed at the prompt is received",
          last_echo(rows) == ">look" and echo_reply(rows) == LAB,
          "echo %r, reply %r" % (last_echo(rows), echo_reply(rows)))

    # 3. ten one-frame taps of L at the prompt
    s.press(" ".join("L" * 10), frames=TAP_FRAMES)
    s.enter()
    wait_ready(s)
    rows = s.rows()
    check("tap: ten one-frame taps echo ten l", last_echo(rows) == ">" + "l" * 10,
          "echo %r" % last_echo(rows))

    # 4. rollover: K pressed and released while O is held (O's row is
    #    scanned first, so a first-key scan never sees K)
    s.press(ROLLOVER, ROLL_FRAMES, gap=0)      # gap 0: O is never released between items
    s.enter()
    wait_ready(s)
    rows = s.rows()
    check("rollover: K under a held O echoes ok", last_echo(rows) == ">ok",
          "echo %r" % last_echo(rows))

    # 4b. held through: exactly one l, so the pop armed the long delay
    down, detail = held_through(s, keys)
    print("held through: " + detail, flush=True)
    s.enter()
    wait_ready(s)
    rows = s.rows()
    if not down:
        inconclusive("held through", "L was not down when the prompt came back (%s) - echo %r"
                     % (detail, last_echo(rows)))
    else:
        check("held through: one l, no repeat inside 35 frames",
              last_echo(rows) == ">l", "echo %r (%s)" % (last_echo(rows), detail))

    # 4c. the same key twice inside one pause
    s.type_text("long\n")
    s.press("L L", frames=DOUBLE_TAP_FRAMES)
    still_paused = prompt_away(s)
    s.enter()
    wait_ready(s)
    rows = s.rows()
    if not still_paused:
        inconclusive("double tap", "the prompt was back before ENTER - echo %r" % last_echo(rows))
    else:
        check("double tap in the pause: ll", last_echo(rows) == ">ll", "echo %r" % last_echo(rows))

    # 4d. overflow: 18 taps in one pause keep the first 15. Valid only
    #     if the prompt was still away after the last tap; ENTER goes
    #     after the prompt (inside the pause it is the dropped 16th press)
    s.type_text("long\n")
    s.press(" ".join("L" * 18), frames=TAP_FRAMES)
    still_paused = prompt_away(s)
    wait_ready(s)
    s.enter()
    wait_ready(s)
    rows = s.rows()
    if not still_paused:
        inconclusive("overflow", "the prompt was back before the last tap - echo %r" % last_echo(rows))
    else:
        check("overflow: 15 of 18 taps kept", last_echo(rows) == ">" + "l" * 15,
              "echo %r" % last_echo(rows))

    # 5. the key that dismisses ANYKEY is not typed
    s.type_text("anyk\n")
    check("anyk: Press any key. shown", seen(s, lambda rows: any("Press any key." in r for r in rows)))
    s.press("L")
    wait_ready(s)
    submit(s, "ook")
    rows = s.rows()
    check("anyk: dismiss key is not typed", last_echo(rows) == ">ook", "echo %r" % last_echo(rows))

    # 6. the key that dismisses More... is not typed
    s.type_text("morex\n")
    check("morex: More... shown", seen(s, lambda rows: any("More..." in r for r in rows)))
    s.press("L")
    wait_ready(s)
    submit(s, "ook")
    rows = s.rows()
    check("morex: dismiss key is not typed", last_echo(rows) == ">ook", "echo %r" % last_echo(rows))

    # 7. the key GETKEY consumed is printed as its code and not typed
    s.type_text("getk\n")
    seen(s, lambda rows: any("press a key" in r for r in rows[_echo_index(rows) + 1:]))
    s.press("L")
    check("getk: key code 108 printed", seen(s, lambda rows: any(r.strip() == "108" for r in rows)))
    wait_ready(s)
    submit(s, "ook")
    rows = s.rows()
    check("getk: consumed key is not typed", last_echo(rows) == ">ook", "echo %r" % last_echo(rows))

    # 8. INKEY consumes its key: the INKY loop polls INKEY until L
    s.type_text("inky\n")
    check("inky: prompt for a key shown",
          seen(s, lambda rows: any("press a key for inkey" in r for r in rows)))
    s.press("L")
    seen(s, lambda rows: "108" in [r.strip() for r in rows[_echo_index(rows) + 1:]])
    wait_ready(s)
    rows = s.rows()
    k = _echo_index(rows)
    below = [r.strip() for r in rows[k + 1:]]
    check("inky: key code 108 printed below the inky echo, no 13", "108" in below and "13" not in below,
          "rows below echo %r" % below[:6])
    submit(s, "ook")
    rows = s.rows()
    check("inky: consumed key is not typed", last_echo(rows) == ">ook", "echo %r" % last_echo(rows))


def main():
    if not LEG.is_dir():
        sys.exit("typeahead_run: %s missing - run tests\\build-tests.ps1 -KbLog" % LEG)
    sd = stage()
    with Session.boot(sd, sd / "nextdaad.nex", MAP) as s:
        run(s, key_session(s))
    if FAILS:
        sys.exit("typeahead_run: %d check(s) failed: %s" % (len(FAILS), ", ".join(FAILS)))
    if INCONCLUSIVE:
        print("typeahead_run: %d check(s) inconclusive: %s" % (len(INCONCLUSIVE), ", ".join(INCONCLUSIVE)))
        sys.exit(2)
    print("typeahead_run: all checks passed")


if __name__ == "__main__":
    main()
