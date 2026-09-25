r"""Single-hook format 3 headers on a live interpreter. No shipped
binary has a format 3 header with one hook entry 0; this boots two,
built by EXTERNS.BAT's builder from tests\xbn\usermods: ua (lineEntry
set, outEntry 0) and uo (lineEntry 0, outEntry set). ua's line hook
counts typed lines in flag 190, uo's output hook counts printed
characters in flag 191.

Usage: python tests\xbn\hookshape.py sd\XBN
The leg is the staged XBN leg (tests\build-tests.ps1 -Xbn); its
GAME.XBN is swapped in a temp copy. Exit 1 on a failed check."""
import argparse, pathlib, shutil, subprocess, sys, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import nleg, symbols  # noqa: E402

PORT = 10033
LINE_FLAG = 190         # OUT_FLAG = 191 is read as the next byte
VERB = "XYZZY"          # unknown to extern.dsf: one line in, a message out
BOOT_FLOOR_S = 2.0      # smartload settle before the lock bytes mean anything
READY_TIMEOUT_S = 30.0


def build(module, out):
    subprocess.run([
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        str(ROOT / "authoring-kit" / "lib" / "xbnbuild.ps1"),
        str(ROOT / "tests" / "xbn" / "usermods" / module),
        "-Out", str(out),
        "-SjasmPlus", str(ROOT / "tools" / "sjasmplus" / "sjasmplus.exe"),
    ], check=True)


def wait_ready(nl):
    """Poll until the input editor is ready: (moreLock, wrapLock) both set
    on two reads a poll apart (nleg.NextLeg.more_state; the pair also holds
    briefly inside the pager, which the second read rules out). No typing
    before this - never type blind into ZEsarUX."""
    deadline = time.time() + READY_TIMEOUT_S
    while time.time() < deadline:
        state = nl.more_state()
        if state == (True, True):
            time.sleep(nleg.SETTLE_POLL_S)
            if nl.more_state() == (True, True):
                return
        elif state == (True, False):
            raise SystemExit("parked on a MORE page - the leg prints more "
                             "than a page before its first prompt")
        time.sleep(nleg.SETTLE_POLL_S)
    raise SystemExit("input editor not ready within %.0fs" % READY_TIMEOUT_S)


def turn(leg, xbn, syms, obj_count, obj_size):
    """Boot the leg with xbn as GAME.XBN and type VERB once. Returns the
    (line, out) counter deltas across that turn."""
    work = pathlib.Path(tempfile.mkdtemp(prefix="hookshape-"))
    sd = work / "sd"
    shutil.copytree(leg, sd)
    shutil.copyfile(xbn, sd / "GAME.XBN")
    shutil.copyfile(ROOT / "build" / "nextdaad.nex", sd / "nextdaad.nex")
    proc = nleg.launch(sd, PORT)
    try:
        z = nleg.wait_for_port(proc, PORT)
        try:
            nl = nleg.NextLeg(z, syms, obj_count, obj_size)
            flags = syms["FLAGS"] + LINE_FLAG
            z.cmd("smartload %s" % (sd / "nextdaad.nex"), deadline=30.0)
            time.sleep(BOOT_FLOOR_S)
            wait_ready(nl)
            nl.disarm_input_timeout()
            before = z.read_memory(flags, 2)
            z.send_keys(VERB)
            z.enter()                   # its own wait covers the key hand-off
            wait_ready(nl)
            after = z.read_memory(flags, 2)
        finally:
            z.close()
    finally:
        proc.kill()
        proc.wait(timeout=10)
        shutil.rmtree(work, ignore_errors=True)
    return ((after[0] - before[0]) & 0xFF, (after[1] - before[1]) & 0xFF)


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
    out = ROOT / "tests" / "out" / "xbn"
    out.mkdir(parents=True, exist_ok=True)
    bad = 0
    for module in ("ua", "uo"):
        xbn = out / ("hookshape-%s.XBN" % module)
        build(module, xbn)
        line, printed = turn(leg, xbn, syms, obj_count, obj_size)
        if module == "ua":
            ok = line == 1 and printed == 0     # one line hook call, no out hook
        else:
            ok = line == 0 and printed != 0     # out hook counted, no line hook
        print("%s %s line+%d out+%d" % ("PASS" if ok else "FAIL", module, line, printed))
        bad += not ok
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
