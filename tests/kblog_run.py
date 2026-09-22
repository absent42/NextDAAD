# Drives the -KbLog leg headless and reads the DEBUG keystroke log.
# Self-check (exit 1 on failure): the ring runs, a held key is received,
# a More page shows. Then the observation: LOOK typed during LONG's pause,
# and again after the prompt, each with its decoded verdicts.
#   .\build.ps1 ; pwsh -File tests\build-tests.ps1 -KbLog ; python tests\kblog_run.py
import pathlib
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
import kblog_dump as kb                              # noqa: E402

LEG = ROOT / "sd" / "KBLOG"
PORT = 10042
HOLD_L = "FFFFFFFFFFFFFDFF00"    # row 6 (H J K L ENTER) bit 1 = L; bit 0 is untouchable


def fail(msg):
    sys.exit("kblog_run: FAIL " + msg)


def snapshot(z):
    raw, ptr = kb.read_ring(z)
    return kb.entries_from(raw, ptr)


def frame_mark(z):
    """frameCounter's low byte now - the cut for 'runs typed after this'."""
    return z.read_memory(kb.sym("FRAMECOUNTER"), 1)[0]


def mark_index(ents, mark):
    """Index of the LAST entry stamped with frame byte `mark` (the ring spans
    512 frames, so the byte can recur)."""
    at = max((k for k, e in enumerate(ents) if e[0] == mark), default=None)
    if at is None:
        fail("frame mark %02X not in the ring - the read came too late" % mark)
    return at


def runs_from(ents, at):
    """Key runs whose first entry is at or after entry `at`."""
    return [r for r in kb.key_runs(ents) if r[0] >= at]


def frames_now(z):
    b = z.read_memory(kb.sym("FRAMECOUNTER"), 2)
    return b[0] | (b[1] << 8)


def main():
    if not LEG.is_dir():
        sys.exit("kblog_run: %s missing - run tests\\build-tests.ps1 -KbLog" % LEG)
    proc, z = kb.launch(LEG, PORT)
    try:
        time.sleep(6.0)
        ents = snapshot(z)
        if len(ents) < 100:
            fail("idle walk only %d entries" % len(ents))
        if any(e[1] for e in ents[-60:]) or ents[-1][2] & 0x7F != kb.ENTERED:
            fail("idle prompt: keys down or state not 'entered'\n" + kb.report(ents[-10:]))
        print("self-check 1: ring runs, idle at the prompt - PASS")

        f0 = frames_now(z)
        z.hold_matrix(HOLD_L)
        time.sleep(1.0)
        z.release_matrix()
        held = (frames_now(z) - f0) & 0xFFFF
        time.sleep(0.3)
        ents = snapshot(z)
        runs = kb.key_runs(ents)
        v = [kb.classify(ents, r) for r in runs]
        if not v or v[-1][0] != "EMITTED" or v[-1][1] != ord("l"):
            fail("held L not received: %s\n%s" % (v, kb.report(ents)))
        n = runs[-1][1] - runs[-1][0] + 1
        if abs(n - held) > 2:
            fail("held L run is %d entries, key held %d frames\n%s" % (n, held, kb.report(ents)))
        print("self-check 2: held L received, run %d entries for %d frames held - PASS" % (n, held))
        z.enter(wait=1.5)                             # submit "l..." (no word)

        z.send_keys("MOREX")
        z.enter(wait=4.0)
        ents = snapshot(z)
        if not any(e[2] & 0x80 and e[2] & 0x7F in (kb.IDLE0, kb.LEFT) for e in ents[-80:]):
            fail("no More page logged after MOREX\n" + kb.report(ents[-20:]))
        z.tap_dismiss_key()
        time.sleep(2.0)
        ents = snapshot(z)
        # the editor holds moreLock too: bit 7 means a More page only in states 0 and 6
        if any(e[2] & 0x80 and e[2] & 0x7F in (kb.IDLE0, kb.LEFT) for e in ents[-20:]) \
                or ents[-1][2] & 0x7F != kb.ENTERED:
            fail("More page still logged after the dismiss, or not back at the prompt\n"
                 + kb.report(ents[-20:]))
        print("self-check 3: More page logged, cleared on dismiss - PASS")

        for label, gap in (("early (inside LONG's pause)", 0.3), ("late (after the prompt)", 4.0)):
            z.send_keys("LONG")
            z.enter(wait=gap)
            mark = frame_mark(z)                      # just before LOOK's first key
            z.send_keys("LOOK")
            z.enter(wait=3.0)
            ents = snapshot(z)
            print("--- observation, LOOK typed %s (runs from frame %02X)" % (label, mark))
            at = mark_index(ents, mark)
            print(kb.report(ents, start=at))
            rs = runs_from(ents, at)
            print("verdicts of the runs typed from the mark: %s" % [kb.classify(ents, r)[0] for r in rs])
    finally:
        try:
            z.close()
        except Exception:
            pass
        proc.kill()
        proc.wait()


if __name__ == "__main__":
    main()
