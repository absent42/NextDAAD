"""Write a copy of a NEX without 16K bank 47 for DeZog serial loads.

dezogif reserves 8K page 94 (16K bank 47, the DEBUG NXB bench bank) and
refuses writes to it, so a NEX holding bank 47 cannot be loaded over
serial. Addresses are unchanged, so the build's SLD still applies. The
NXB bench is unusable in a session loaded from the copy.

Usage: python tests/nex_dezog.py [in.nex] [out.nex]
"""
import sys

BANK = 47
ORDER = [5, 2, 0, 1, 3, 4] + list(range(6, 112))
SIZE16K = 16384


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else 'build/nextdaad.nex'
    dst = sys.argv[2] if len(sys.argv) > 2 else 'build/nextdaad-dezog.nex'
    d = bytearray(open(src, 'rb').read())
    if d[0:4] != b'Next':
        sys.exit(f'{src}: not a NEX file')
    if d[10] != 0:
        sys.exit(f'{src}: loading screen present, not supported')
    present = [b for b in ORDER if d[18 + b]]
    if BANK not in present:
        sys.exit(f'{src}: bank {BANK} not present, nothing to strip')
    if 512 + len(present) * SIZE16K > len(d):
        sys.exit(f'{src}: bank data shorter than the header states')
    at = 512 + present.index(BANK) * SIZE16K
    del d[at:at + SIZE16K]
    d[18 + BANK] = 0
    d[9] -= 1
    open(dst, 'wb').write(d)
    print(f'{dst}: {len(d)} bytes, banks {[b for b in present if b != BANK]}')


if __name__ == '__main__':
    main()
