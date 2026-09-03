# Drives tests\spraud.dsf on ZEsarUX and checks the DEBUG sprite snapshot
# after every step. Control-flow proof only: the emulator cannot grade the
# audio, so the silicon sheet carries the listening check and this reader
# proves A1-A4 - four sets live, the tick advancing under the AKY music, the
# stop-all and restart under music (pattern DMA under the music ISR), and the
# music stop leaving the scene alone. A5-A9 (every sampled effect) are
# silicon-only: sfx_stream_open's run-count loop never terminates on the odd
# DISK_FILEMAP byte count ZEsarUX's esxDOS handler returns (see the fixture).
#
# Run from the repo root, after
#     .\build.ps1                            (DEBUG - the snapshot is DEBUG-only)
#     pwsh -File tests\build-tests.ps1 -SprAud
#
#     python tests\spraud_dump.py [--port N] [-v]
#
# Snapshot decoding, the step driver and the launcher are tests\sprites_dump.py's.
import argparse
import os
import pathlib
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
import sprites_dump as sd                              # noqa: E402
from sprites_dump import SR, State, step, expect       # noqa: E402

LEG = ROOT / "sd" / "SPRAUD"
FOUR = [2, 6, 20, 21]


def advancing(z, n, budget=1.5):
    """True when set n's (frame, count) pair moves within the budget - the
    same phase-safe idiom sprites_dump uses at S1."""
    s = State(z); r = s.live()
    pairs = [(r[n][SR["FRAME"]], r[n][SR["COUNT"]])]
    deadline = time.time() + budget
    while True:
        time.sleep(0.08); s = State(z); r = s.live()
        if n not in r:
            return False
        pairs.append((r[n][SR["FRAME"]], r[n][SR["COUNT"]]))
        if len(pairs) >= 3 and (any(p != pairs[0] for p in pairs[1:])
                                or time.time() > deadline):
            return any(p != pairs[0] for p in pairs[1:])


def run(z, verbose):
    def show(tag, s):
        if verbose:
            print("--- %s\n%s" % (tag, s.summary()))
    time.sleep(4.0)                    # PRO 0 starts four sets at boot
    s = State(z); show("A1", s); r = s.live()
    expect(sorted(r) == FOUR, "A1 sets 2, 6, 20, 21 live, got %r" % sorted(r))
    expect(r[20][SR["XLO"]] == 132 and r[20][SR["Y"]] == 72, "A1 set 20 override (100,40) is plane (132,72)")
    expect(r[21][SR["XLO"]] == 92 and r[21][SR["Y"]] == 142, "A1 set 21 override (60,110) is plane (92,142)")
    expect(r[6][SR["KIND"]] == 1 and s.claim == 0b110, "A1 set 6 4-bit holds blocks 1,2")
    expect(s.hook & 2, "A1 HOOK_SPR armed")
    expect(s.loads == 4, "A1 four SD loads (got %d)" % s.loads)
    loads = s.loads
    s = step(z); show("A2", s)
    expect(sorted(s.live()) == FOUR and s.loads == loads, "A2 music start leaves the four sets alone")
    expect(advancing(z, 2), "A2 torch keeps ticking under the music")
    # A2 is a GETMS tracking loop: step() sends a space and polls. The restart
    # re-uploads every pattern by DMA while the music ISR runs. 006 restarts
    # first, so its channel flips from 1 to 0: the proof the restart ran.
    s = step(z, until=lambda st: sorted(st.live()) == FOUR and st.live()[6][SR["CHAN"]] == 0)
    show("A3", s); r = s.live()
    expect(sorted(r) == FOUR, "A3 all four restarted under music, got %r" % sorted(r))
    expect(r[6][SR["CHAN"]] == 0 and r[2][SR["CHAN"]] == 1, "A3 restart order 6 then 2 flipped the channels")
    expect(r[20][SR["XLO"]] == 132 and r[20][SR["Y"]] == 72 and r[21][SR["XLO"]] == 92 and r[21][SR["Y"]] == 142,
           "A3 sets 20 and 21 back at their flag spots (132,72) and (92,142)")
    expect(s.loads == loads, "A3 restarts were cache hits (loads %d, was %d)" % (s.loads, loads))
    expect(advancing(z, 2), "A3 torch ticking after the restart")
    s = step(z); show("A4", s)
    expect(sorted(s.live()) == FOUR, "A4 music stop leaves the four sets running")
    expect(advancing(z, 2), "A4 torch ticking in silence")
    print("spraud_dump: A1-A4 pass (A5-A9 sampled effects: silicon only)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=10017)
    ap.add_argument("--work", default=None, help="scratch card directory")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--leg", default=str(LEG), help="leg folder to boot (default sd\\SPRAUD)")
    args = ap.parse_args()
    leg = pathlib.Path(args.leg)
    if not sd.ZESARUX.exists():
        sys.exit("ZEsarUX not found at %s" % sd.ZESARUX)
    if not sd.NEX.exists():
        sys.exit("build\\nextdaad.nex missing - run .\\build.ps1 (DEBUG)")
    if not (leg / "GAME.DDB").exists():
        sys.exit("%s\\GAME.DDB missing - run tests\\build-tests.ps1 -SprAud" % leg)
    if not sd.port_free(args.port):
        sys.exit("port %d is already listening" % args.port)
    work = args.work or os.path.join(os.environ.get("TEMP", "."), "spraud_dump")
    os.makedirs(work, exist_ok=True)
    proc, z = sd.launch(work, args.port, leg=leg)
    try:
        return run(z, args.verbose)
    finally:
        try:
            z.close()
        except Exception:
            pass
        proc.kill()
        proc.wait(timeout=20)


if __name__ == "__main__":
    sys.exit(main())
