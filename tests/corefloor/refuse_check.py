"""Core-floor refusal on CSpect (tests/cspect): boots the Release build with the reported
core set to each version (-major/-minor, NR $01/$0E) and reads the tilemap.

    ./build.ps1 -Release
    python tests/corefloor/refuse_check.py [--port N]

--port is the harness MCP port (tests/cspect/launcher.py PORT_RANGE, default the first free).
The border is not visible (the tilemap covers it), so the witness is core_refuse's
out ($FE),a: below 3.03.03 it must run with A = ERR_BORDER_CORE, then at core_refuse.halt
row 0 must read the refusal text and nothing else; at or above it that out must not run
before PAST_GATE, and the interpreter must then print something other than the refusal.
Exit 1 on a failed case.
"""
import argparse
import pathlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from cspect import Session                           # noqa: E402

NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
SYM = ROOT / "build" / "NEXTDAAD.SYM"
MESSAGE = "NextDAAD needs core 3.03.03 or later"
# Release calls it right after txt_init clears the tilemap (src/main.asm:29-31); until then
# $6000 holds whatever RAM held at power-on.
PAST_GATE = "RAM_DETECT"
STOP_S = 30.0                                        # host deadline for a boot-path stop
PRINT_S = 30.0                                       # host deadline for the first text

# (reported core, refused)
CASES = [
    ((3, 2, 1), True),
    ((3, 3, 2), True),
    ((3, 3, 3), False),
    ((3, 4, 0), False),
]


def err_border():
    m = re.search(r"^ERR_BORDER_CORE\s+equ\s+(\d+)", (ROOT / "src" / "nextdaad.inc").read_text(
        encoding="utf-8"), re.M)
    if not m:
        raise SystemExit("refuse_check: ERR_BORDER_CORE not found in src/nextdaad.inc")
    return int(m.group(1))


def nr_values(version):
    """NR $01 (major.minor nibbles) and NR $0E (sub) for a core version."""
    return (version[0] << 4) | version[1], version[2]


def out_address(s, border):
    """core_refuse's out ($FE),a, checked against the loaded image."""
    at = s.sym("CORE_REFUSE")
    code = s.read(at, 4)
    if code != bytes((0x3E, border, 0xD3, 0xFE)):
        raise SystemExit("refuse_check: core_refuse at $%04X holds %s, not ld a,%d / out ($FE),a"
                         % (at, code.hex(" "), border))
    return at + 2


def run_case(version, refused, border, port, work):
    """(ok, detail) for one reported core."""
    sd = work / ("%d.%d.%d" % version)
    sd.mkdir(parents=True)
    nex = sd / "NEXTDAAD.NEX"
    shutil.copyfile(NEX, nex)
    major, minor = nr_values(version)
    with Session.boot(sd, nex, MAP, paused=True, major=major, minor=minor, port=port) as s:
        print("CSpect PID %d on MCP port %d, NR $01=$%02X NR $0E=$%02X"
              % (s.pid, s.inst.port, major, minor), flush=True)
        at = out_address(s, border)
        s.set_breakpoint(at)
        s.set_breakpoint(PAST_GATE)
        s.resume()
        try:
            pc = s.wait_until(s.stopped_at, STOP_S, what="core_refuse's out or %s" % PAST_GATE)
        except TimeoutError as e:
            text = [r.strip() for r in s.rows() if r.strip()]
            return False, "%s; screen %s" % (e, text[:2] or "blank")
        if pc != at:
            if refused:
                return False, "reached %s, out ($FE),a never ran" % PAST_GATE
        elif not refused:
            return False, "out ($FE),a at $%04X ran with A=%d" % (at, s.regs()["A"])
        else:
            a = s.regs()["A"]
            s.clear_breakpoint(at)
            halt = s.run_to("CORE_REFUSE@HALT", STOP_S)
            rows = s.rows()
            shown = rows[0].strip() == MESSAGE
            rest = [r.strip() for r in rows[1:] if r.strip()]
            ok = a == border and halt == s.sym("CORE_REFUSE@HALT") and shown and not rest
            return ok, ("out ($FE),a at $%04X ran with A=%d; row0=%r; other rows %s"
                        % (pc, a, rows[0].strip()[:40], rest[:2] or "blank"))
        s.clear_breakpoint(PAST_GATE)
        s.clear_breakpoint(at)
        s.resume()

        def printed():
            return [r.strip() for r in s.rows() if r.strip()]
        got = s.wait_until(printed, PRINT_S, what="the interpreter's first text")
        ok = not any(MESSAGE in t for t in got)
        return ok, "out ($FE),a not reached by %s; row0=%r" % (PAST_GATE, got[0][:40])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=None)
    port = ap.parse_args().port
    if "\tRelease" not in SYM.read_text(encoding="utf-8", errors="replace").split("\n", 2)[1]:
        raise SystemExit("build/nextdaad.nex is not a Release build: run ./build.ps1 -Release")
    border = err_border()
    work = ROOT / "tests" / "out" / "corefloor" / "refuse"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    failed = 0
    for version, refused in CASES:
        ok, detail = run_case(version, refused, border, port, work)
        print("%s core %d.%02d.%02d %s: %s"
              % ("PASS" if ok else "FAIL", version[0], version[1], version[2],
                 "refused" if refused else "boots", detail), flush=True)
        failed += not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
