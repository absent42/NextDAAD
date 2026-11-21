#!/usr/bin/env python3
"""tests/mkrawbad.py - copy a raw NXV clip with one header fault (refusal fixtures).

python tests\\mkrawbad.py --in <raw.vid> --out <bad.vid> --fault <name>
python tests\\mkrawbad.py --diff <a.vid> <b.vid>

Faults (header bytes only; the input must be a raw clip, flags $13; the width
faults need a 320-surface clip, width code 1):
  flags11      flags $11 (raw without direct-serve)
  flags03mono  flags $03 and channels 1 (mono without raw)
  width322     raw width word 322
  width0       raw width word 0
  width6       raw width word 6
  capplus1     frame cap + 1
  flags1b      flags $1B (bit 3 set)
Prints one line per changed offset: "offset N: old -> new" (hex bytes).
--diff prints "differs at: N N ..." (or "differs at: none") and the sizes.
"""
import argparse
import sys
from pathlib import Path

OFF_ACHAN, OFF_FLAGS, OFF_CAP, OFF_RAWW = 9, 12, 21, 23


def _word(b, off, v):
    b[off:off + 2] = int(v).to_bytes(2, "little")


FAULTS = {
    "flags11": lambda b: b.__setitem__(OFF_FLAGS, 0x11),
    "flags03mono": lambda b: (b.__setitem__(OFF_FLAGS, 0x03), b.__setitem__(OFF_ACHAN, 1)),
    "width322": lambda b: _word(b, OFF_RAWW, 322),
    "width0": lambda b: _word(b, OFF_RAWW, 0),
    "width6": lambda b: _word(b, OFF_RAWW, 6),
    "capplus1": lambda b: _word(b, OFF_CAP, int.from_bytes(b[OFF_CAP:OFF_CAP + 2], "little") + 1),
    "flags1b": lambda b: b.__setitem__(OFF_FLAGS, 0x1B),
}


def diff(a, b):
    n = min(len(a), len(b))
    offs = [i for i in range(min(n, 512)) if a[i] != b[i]]
    if a[512:n] != b[512:n]:
        offs += [512 + i for i, (x, y) in enumerate(zip(a[512:n], b[512:n])) if x != y]
    return offs


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--in", dest="src")
    ap.add_argument("--out")
    ap.add_argument("--fault", choices=sorted(FAULTS))
    ap.add_argument("--diff", nargs=2, metavar="VID")
    a = ap.parse_args(argv)
    if a.diff:
        x, y = (Path(p).read_bytes() for p in a.diff)
        offs = diff(x, y)
        print("differs at: " + (" ".join(str(o) for o in offs) if offs else "none"))
        print(f"sizes: {len(x)} {len(y)}")
        return 0
    if not (a.src and a.out and a.fault):
        ap.error("--in, --out and --fault are required")
    data = bytearray(Path(a.src).read_bytes())
    if len(data) < 512 or data[0:5] != b"NXVID" or data[OFF_FLAGS] != 0x13:
        print(f"mkrawbad: {a.src} is not a raw clip (flags $13)", file=sys.stderr)
        return 1
    if a.fault.startswith("width") and data[6] != 1:
        print(f"mkrawbad: {a.fault} needs a 320-surface clip (width code 1): "
              f"the player ignores the width word on code 0", file=sys.stderr)
        return 1
    old = bytes(data[:512])
    FAULTS[a.fault](data)
    Path(a.out).write_bytes(bytes(data))
    for i in range(512):
        if old[i] != data[i]:
            print(f"offset {i}: {old[i]:02x} -> {data[i]:02x}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
