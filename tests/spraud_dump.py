r"""Drives tests\spraud.dsf on CSpect (tests\cspect) and checks the DEBUG sprite snapshot after
every step. Control-flow proof only: -sound runs CSpect silent, so the silicon sheet carries
the listening check and this reader proves A1-A4 - four sets live, the tick advancing under
the AKY music, the stop-all and restart under music (pattern DMA under the music ISR), and
the music stop leaving the scene alone. A5-A11 (every sampled effect) are silicon-only:
sfx_stream_open streams over raw SD SPI (src\audio\streamfx.asm), which CSpect cannot run.

Run from the repo root, after
    .\build.ps1                            (DEBUG - the snapshot is DEBUG-only)
    pwsh -File tests\build-tests.ps1 -SprAud

    python tests\spraud_dump.py [--port N] [--work DIR] [-v]

--port is the harness MCP port (tests\cspect\launcher.py PORT_RANGE, default the first free).
Snapshot decoding, the step driver, the torch sampler and boot are tests\sprites_dump.py's."""
import argparse
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
import sprites_dump as sd                              # noqa: E402
from sprites_dump import SR, State, step, expect       # noqa: E402

LEG = ROOT / "sd" / "SPRAUD"
FOUR = [2, 6, 20, 21]


def advancing(s, n):
    """True when set n's (frame, count) pair moves (sprites_dump.torch_moves)."""
    return sd.torch_moves(s, n)[0]


def run(s, verbose):
    def show(tag, st):
        if verbose:
            print("--- %s\n%s" % (tag, st.summary()))
    # PRO 0 starts four sets at boot
    expect(sd.wait_text(s, "A1 four sets"), "A1 message never printed")
    st = State(s); show("A1", st); r = st.live()
    expect(sorted(r) == FOUR, "A1 sets 2, 6, 20, 21 live, got %r" % sorted(r))
    expect(r[20][SR["XLO"]] == 132 and r[20][SR["Y"]] == 72, "A1 set 20 override (100,40) is plane (132,72)")
    expect(r[21][SR["XLO"]] == 92 and r[21][SR["Y"]] == 142, "A1 set 21 override (60,110) is plane (92,142)")
    expect(r[6][SR["KIND"]] == 1 and st.claim == 0b110, "A1 set 6 4-bit holds blocks 1,2")
    expect(st.hook & 2, "A1 HOOK_SPR armed")
    expect(st.loads == 4, "A1 four SD loads (got %d)" % st.loads)
    loads = st.loads
    st = step(s, "A2 SFX 6 7"); show("A2", st)
    expect(sorted(st.live()) == FOUR and st.loads == loads, "A2 music start leaves the four sets alone")
    expect(advancing(s, 2), "A2 torch keeps ticking under the music")
    # A2 is a GETMS tracking loop. The restart re-uploads every pattern by DMA while the
    # music ISR runs; 006 restarts first, so its channel flips from 1 to 0
    st = step(s, "A3 stop-all", until=lambda x: sorted(x.live()) == FOUR and x.live()[6][SR["CHAN"]] == 0)
    show("A3", st); r = st.live()
    expect(sorted(r) == FOUR, "A3 all four restarted under music, got %r" % sorted(r))
    expect(r[6][SR["CHAN"]] == 0 and r[2][SR["CHAN"]] == 1, "A3 restart order 6 then 2 flipped the channels")
    expect(r[20][SR["XLO"]] == 132 and r[20][SR["Y"]] == 72 and r[21][SR["XLO"]] == 92 and r[21][SR["Y"]] == 142,
           "A3 sets 20 and 21 back at their flag spots (132,72) and (92,142)")
    expect(st.loads == loads, "A3 restarts were cache hits (loads %d, was %d)" % (st.loads, loads))
    expect(advancing(s, 2), "A3 torch ticking after the restart")
    st = step(s, "A4 SFX 0 8"); show("A4", st)
    expect(sorted(st.live()) == FOUR, "A4 music stop leaves the four sets running")
    expect(advancing(s, 2), "A4 torch ticking in silence")
    print("spraud_dump: A1-A4 pass (A5-A11 sampled effects: silicon only)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--work", default=None, help="scratch card directory")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--leg", default=str(LEG), help="leg folder to boot (default sd\\SPRAUD)")
    args = ap.parse_args()
    leg = pathlib.Path(args.leg)
    if not sd.NEX.exists():
        sys.exit("build\\nextdaad.nex missing - run .\\build.ps1 (DEBUG)")
    if not (leg / "GAME.DDB").exists():
        sys.exit("%s\\GAME.DDB missing - run tests\\build-tests.ps1 -SprAud" % leg)
    work = args.work or os.path.join(os.environ.get("TEMP", "."), "spraud_dump")
    os.makedirs(work, exist_ok=True)
    with sd.boot(work, leg=leg, port=args.port) as s:
        return run(s, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
