r"""zxnDDMA probe on the CSpect harness: does this CSpect emulate the blitter modes NextDAAD uses?

Run from the repo root after .\build.ps1:

    python tests\cspect\ddma_probe.py [--port N] [--work DIR]

Boots build\nextdaad.nex stopped at its entry, plants a stub that sends three transfers on
port $6B and reads the memory back:
  fill         physical fill, 300 bytes
  rect         physical 2D copy, 4 rows x 5 bytes, source stride 7, destination stride 256
  mmu-overlap  MMU-addressed 2D copy, 6 rows x 40 bytes, both strides 160 (the scroll's shape)
Exit 0 when all three match, 1 otherwise."""
import argparse
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from cspect import Session                             # noqa: E402

NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
STUB = 0x6000
FILL_BANK, SRC_BANK, DST_BANK, MMU_BANK = 40, 41, 42, 43


def phys(bank, offset):
    """(extended byte, low 16 bits) of a 16K bank offset."""
    return 4 + (bank >> 2), ((bank & 3) << 14) + offset


def word(v):
    return [v & 0xFF, v >> 8]


def stream():
    fe, fl = phys(FILL_BANK, 0x0100)
    se, sl = phys(SRC_BANK, 0x0100)
    de, dl = phys(DST_BANK, 0x0200)
    tail = [0x54, 0x02, 0x50, 0x02]                    # WR1, WR2: memory, incrementing, cycle 2
    s = [0xC3, 0xDF, 0x09, 0xDB, fe, 0xF7, 0xA5,
         0x7D, 0, 0, *word(300), *tail, 0xAD, *word(fl), 0x82, 0xCF, 0x87]
    s += [0xC3, 0xDF, 0x03, 0xD7, se, 0xDB, de,
          0xE3, *word(5), 0xE7, *word(4), 0xEB, *word(7), 0xEF, *word(256),
          0x7D, *word(sl), 1, 0, *tail, 0xAD, *word(dl), 0x82, 0xCF, 0x87]
    s += [0xC3, 0xDF, 0x02,
          0xE3, *word(40), 0xE7, *word(6), 0xEB, *word(160), 0xEF, *word(160),
          0x7D, *word(0xC0A0), 1, 0, *tail, 0xAD, *word(0xC000), 0x82, 0xCF, 0x87]
    s += [0xDF, 0x00]
    return bytes(s)


def first_diff(got, want):
    return next((i for i, (g, w) in enumerate(zip(got, want)) if g != w), None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--work", default=str(ROOT / "tests" / "out" / "ddma_probe"))
    a = ap.parse_args()
    sd = pathlib.Path(a.work).resolve() / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    sd.mkdir(parents=True)
    shutil.copyfile(NEX, sd / "nextdaad.nex")

    data = stream()
    assert len(data) < 256
    code = bytes([0xED, 0x91, 0x56, MMU_BANK * 2,      # nextreg MMU6, bank 43 low page
                  0x21, *word(STUB + 14),               # ld hl, data
                  0x01, 0x6B, len(data),                # ld bc: B = count, C = port
                  0xED, 0xB3,                           # otir
                  0x18, 0xFE])                          # jr $
    assert len(code) == 14
    end = STUB + 12
    blob = code + data

    src = bytes((i * 5 + 1) & 0xFF for i in range(64))
    mmu = bytearray((i * 7 + 3) & 0xFF for i in range(0x500))
    bad = 0
    with Session.boot(sd, sd / "nextdaad.nex", MAP, paused=True, port=a.port) as s:
        s.write_page(FILL_BANK * 2, 0, bytes([0x11]) * 0x400)
        s.write_page(SRC_BANK * 2, 0x100, src)
        s.write_page(DST_BANK * 2, 0, bytes([0x22]) * 0x600)
        s.write_page(MMU_BANK * 2, 0, bytes(mmu))
        s.write(STUB, blob)
        s.set_regs(PC=STUB)
        pc = s.run_to(end, 10.0)
        if pc != end:
            print(f"FAIL stub stopped at ${pc:04X}, not ${end:04X}")
            return 1

        want = bytearray([0x11]) * 0x400
        want[0x100:0x100 + 300] = bytes([0xA5]) * 300
        got = s.read_page(FILL_BANK * 2, 0, 0x400)
        d = first_diff(got, want)
        print("PASS ddma fill" if d is None else f"FAIL ddma fill at offset ${d:04X}: {got[d]:02X} not {want[d]:02X}")
        bad += d is not None

        want = bytearray([0x22]) * 0x600
        for r in range(4):
            want[0x200 + r * 256:0x200 + r * 256 + 5] = src[r * 7:r * 7 + 5]
        got = s.read_page(DST_BANK * 2, 0, 0x600)
        d = first_diff(got, want)
        print("PASS ddma rect" if d is None else f"FAIL ddma rect at offset ${d:04X}: {got[d]:02X} not {want[d]:02X}")
        bad += d is not None

        want = bytearray(mmu)
        for r in range(6):
            for i in range(40):
                want[r * 160 + i] = want[160 + r * 160 + i]
        got = s.read_page(MMU_BANK * 2, 0, 0x500)
        d = first_diff(got, want)
        print("PASS ddma mmu-overlap" if d is None else f"FAIL ddma mmu-overlap at offset ${d:04X}: {got[d]:02X} not {want[d]:02X}")
        bad += d is not None
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
