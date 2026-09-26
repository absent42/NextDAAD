r"""playername module (fns 20-23) on a live interpreter, through the
-XbnAll leg's extern.dsf verbs XNMU/XNMA/XNMK. Each step types a line,
waits for the input editor, then checks the new output rows and the
name bytes in the extern state area (XBN_STATE + 111, 17 bytes).

Usage: python tests\xbn\namecheck.py sd\XBN
The leg is staged by tests\build-tests.ps1 -XbnAll. Exit 1 on a failed
check."""
import argparse, pathlib, shutil, sys, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import nleg, symbols, tilemap, zrcp  # noqa: E402

PORT = 10034
TM_MAP = 0x6000
NAME_ADDR = 0xBF80 + 111        # XBN_STATE + playername's claim
NAME_LEN = 17
BOOT_FLOOR_S = 2.0
READY_TIMEOUT_S = 30.0

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


def wait_ready(nl):
    """Input editor ready: (moreLock, wrapLock) both set on two reads a
    poll apart. Never type before this."""
    deadline = time.time() + READY_TIMEOUT_S
    while time.time() < deadline:
        state = nl.more_state()
        if state == (True, True):
            time.sleep(nleg.SETTLE_POLL_S)
            if nl.more_state() == (True, True):
                return
        elif state == (True, False):
            raise SystemExit("parked on a MORE page")
        time.sleep(nleg.SETTLE_POLL_S)
    raise SystemExit("input editor not ready within %.0fs" % READY_TIMEOUT_S)


def type_line(z, nl, text):
    # Spaces one key at a time: ZRCP collapses them inside a string.
    word = ""
    for ch in text:
        if ch == " ":
            if word:
                z.send_keys(word)
                word = ""
            z.cmd("send-keys-ascii %d 32" % zrcp.KEY_DELAY_MS, wait=0.2)
        else:
            word += ch
    if word:
        z.send_keys(word)
    z.enter()
    wait_ready(nl)


def tail_rows(z, n=4):
    rows, _ = tilemap.decode(z.read_memory(TM_MAP, tilemap.GRID_BYTES))
    body = [r.rstrip() for r in rows if r.strip()]
    return "\n".join(body[-n:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("leg")
    args = ap.parse_args()
    leg = (ROOT / args.leg).resolve()
    if nleg.port_already_listening(PORT):
        raise SystemExit("port %d taken - close the stale ZEsarUX" % PORT)
    syms = symbols.load_symbols(ROOT / "build" / "nextdaad.map")
    obj_size = symbols.load_obj_size(ROOT / "src" / "nextdaad.inc")
    obj_count = (leg / "GAME.DDB").read_bytes()[3]
    work = pathlib.Path(tempfile.mkdtemp(prefix="namecheck-"))
    sd = work / "sd"
    shutil.copytree(leg, sd)
    shutil.copyfile(ROOT / "build" / "nextdaad.nex", sd / "nextdaad.nex")
    proc = nleg.launch(sd, PORT)
    bad = 0
    try:
        z = nleg.wait_for_port(proc, PORT)
        try:
            nl = nleg.NextLeg(z, syms, obj_count, obj_size)
            z.cmd("smartload %s" % (sd / "nextdaad.nex"), deadline=30.0)
            time.sleep(BOOT_FLOOR_S)
            wait_ready(nl)
            nl.disarm_input_timeout()
            for verb, answer, marker, name in STEPS:
                type_line(z, nl, verb)
                if answer is not None:
                    type_line(z, nl, answer)
                shown = tail_rows(z)
                raw = bytes(z.read_memory(NAME_ADDR, NAME_LEN))
                stored = raw.split(b"\0", 1)[0]
                ok = marker in shown and (name is None or stored == name)
                print("%s %-5s %-28r -> %r name=%r" % ("PASS" if ok else "FAIL", verb,
                      answer, marker, stored))
                if not ok:
                    print("  screen tail:\n    " + shown.replace("\n", "\n    "))
                    bad += 1
        finally:
            z.close()
    finally:
        proc.kill()
        proc.wait(timeout=10)
        shutil.rmtree(work, ignore_errors=True)
    print("%d step(s), %d failed" % (len(STEPS), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
