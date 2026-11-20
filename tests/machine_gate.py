"""Machine-nibble acceptance matrix: which databases does NextDAAD boot?

    .\\build.ps1
    pwsh -File tests\\build-tests.ps1 -BigDdb
    python tests\\machine_gate.py [--port N] [--keep]

Boots one database per case on CSpect (tests\\cspect) with byte 1 of the header - the
machine/language byte - patched to a different value each time, and reads the
tilemap to see whether the interpreter ran the game or refused it. A case ends at
fatal's halt (breakpoint) or at the input editor after the accept marker.
--port is the harness MCP port (tests\\cspect\\launcher.py PORT_RANGE, default the first free).

WHAT IT PINS. src\\file.asm's ddb_load masks the machine nibble and compares it
against DDB_MACHINE_NXD, so acceptance depends on the HIGH nibble alone and the
low nibble (the language) must not affect it. Everything else is refused with
"NextDAAD: DDB wrong machine - E4" before the game starts.

THE EXPECTATIONS HERE ARE THE INVERSE OF THE ONES THIS PROBE WAS BORN WITH.
The scratchpad version that drove the E4 work expected machine 1 - the classic
ZX target - to be ACCEPTED, because at that point it was. Classic support was
dropped afterwards: this branch reads NextDAAD-target databases only, so 0x10
and 0x11 are now correctly REFUSED. If this file ever reports a failure on
those two, the fix is not to loosen the expectation.

Not wired into tests\\build-tests.ps1 on purpose - it boots an emulator once per
case. Run it when the acceptance rule itself changes.
"""
import argparse
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tests'))
sys.path.insert(0, str(ROOT / 'tests' / 'xbn'))

from cspect import Session  # noqa: E402
import xbnrun               # noqa: E402

# The fixture is the oversize one deliberately: its first line is a marker
# printed by MESSAGE 254, so an ACCEPTED case proves the interpreter got far
# enough to resolve a pointer past 31744, not merely that it did not refuse.
FIXTURE = ROOT / 'tests' / 'out' / 'bigddb.ddb'
NEX = ROOT / 'build' / 'nextdaad.nex'
MAP = ROOT / 'build' / 'nextdaad.map'
ACCEPT_MARK = 'BIGDDB TAIL OK'
REFUSE_MARK = 'wrong machine'
FATAL_HALT = 'FATAL@HALT'
BOOT_S = 30.0                   # host deadline for the marker or fatal's halt

# (byte 1, expected accepted, what the value is)
CASES = [
    (0xC0, True, 'NEXTDAAD, English - the target this build reads'),
    (0xC1, True, 'NEXTDAAD, Spanish - language must not affect acceptance'),
    (0xCF, True, 'NEXTDAAD, language 15 - the whole low nibble is ignored'),
    (0x10, False, 'classic ZX, English - accepted until classic support was dropped'),
    (0x11, False, 'classic ZX, Spanish - the other half of the old pair'),
    (0x00, False, 'machine 0'),
    (0x20, False, 'CPC'),
    (0x40, False, 'MSX'),
    (0x80, False, 'PC'),
    (0xB0, False, 'the nibble immediately below NEXTDAAD'),
    (0xD0, False, 'the nibble immediately above NEXTDAAD'),
    (0xF0, False, 'machine 15'),
]


def read_screen(sd, nex, port):
    """Boot one prepared folder; its tilemap rows once fatal halts or, after the accept
    marker, the input editor is ready (rows as they stand if neither comes)."""
    with Session.boot(sd, nex, MAP, paused=True, port=port) as s:
        print('  CSpect PID %d on MCP port %d' % (s.pid, s.inst.port), flush=True)
        halt = s.sym(FATAL_HALT)
        s.set_breakpoint(halt)
        s.resume()

        def ended():
            if s.stopped_at() == halt:
                return 'fatal'
            return 'accept' if ACCEPT_MARK in '\n'.join(s.rows()) else None
        try:
            if s.wait_until(ended, BOOT_S, what='the accept marker or %s' % FATAL_HALT) == 'accept':
                xbnrun.wait_ready(s)
        except (TimeoutError, SystemExit) as e:
            print('  no end state: %s' % e)
        return s.rows()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=None)
    ap.add_argument('--keep', action='store_true',
                    help='keep the per-case boot folders for inspection')
    args = ap.parse_args()

    if not FIXTURE.exists():
        raise SystemExit('no %s - run tests\\build-tests.ps1 first' % FIXTURE)
    if not NEX.exists():
        raise SystemExit('no %s - run .\\build.ps1 first' % NEX)

    base = FIXTURE.read_bytes()
    work = ROOT / 'tests' / 'out' / 'machinegate'
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)

    failures = []
    for value, expect_ok, what in CASES:
        case = work / ('%02X' % value)
        case.mkdir()
        patched = bytearray(base)
        patched[1] = value
        (case / 'GAME.DDB').write_bytes(bytes(patched))
        nex = case / 'NEXTDAAD.NEX'
        shutil.copyfile(NEX, nex)

        rows = read_screen(case, nex, args.port)
        joined = '\n'.join(rows)
        accepted = ACCEPT_MARK in joined
        refused = REFUSE_MARK in joined

        if accepted and refused:
            verdict, ok = 'BOTH?', False
        elif accepted:
            verdict, ok = 'accepted', expect_ok
        elif refused:
            verdict, ok = 'refused E4', not expect_ok
        else:
            verdict, ok = 'NEITHER', False

        first = next((r.strip() for r in rows if r.strip()), '(blank screen)')
        print('  %02X  %-10s %-4s  %-52s | %s'
              % (value, verdict, 'ok' if ok else 'FAIL', what, first[:52]), flush=True)
        if not ok:
            failures.append((value, verdict, what, first))

    if not args.keep:
        shutil.rmtree(work, ignore_errors=True)

    print()
    if failures:
        print('%d of %d cases FAILED:' % (len(failures), len(CASES)))
        for value, verdict, what, first in failures:
            print('  %02X (%s): %s - screen said %r' % (value, what, verdict, first))
        return 1
    print('all %d cases as expected: C0/C1/CF accepted, every other machine '
          'nibble refused with E4' % len(CASES))
    return 0


if __name__ == '__main__':
    sys.exit(main())
