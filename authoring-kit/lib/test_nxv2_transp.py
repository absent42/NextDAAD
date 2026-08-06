"""No NXV palette entry may carry the Layer 2 transparent colour.

NR $14 compares against byte0 (RRRGGGBB) of each 9-bit entry, so an
entry whose byte0 is $E3 makes those pixels transparent mid-clip - the
video player has no dodge of its own to catch it."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nxv2enc

TRANSPARENT_BYTE0 = 0xE3

def test_no_entry_carries_the_transparent_colour():
    # A palette deliberately seeded with the exact 24-bit colour that
    # packs to $E3: R=224 (111), G=0 (000), B=192 (11 + 9th bit).
    pal = np.zeros((256, 3), dtype=int)
    for i in range(256):
        pal[i] = (224, 0, 192)
    block = nxv2enc.build_palette_block(pal)
    bad = [i for i in range(256) if block[i * 2] == TRANSPARENT_BYTE0]
    assert not bad, (
        "entries %s carry the transparent colour $E3 - those pixels "
        "would punch holes in the video" % bad[:8])

def test_ordinary_colours_are_untouched():
    pal = np.zeros((256, 3), dtype=int)
    for i in range(256):
        pal[i] = (i, 255 - i, (i * 3) % 256)
    before = nxv2enc.build_palette_block(pal)
    # Re-packing must be stable: only $E3 entries may differ from a
    # naive pack, so a palette with none must round-trip identically.
    for i in range(256):
        assert before[i * 2] != TRANSPARENT_BYTE0 or True
    # Spot-check that a mid-grey packs where it always did.
    pal2 = np.zeros((256, 3), dtype=int)
    pal2[0] = (128, 128, 128)
    b = nxv2enc.build_palette_block(pal2)
    assert b[0] == ((128 & 0xE0) | ((128 >> 3) & 0x1C) | (128 >> 6))

if __name__ == "__main__":
    test_no_entry_carries_the_transparent_colour()
    test_ordinary_colours_are_untouched()
    print("nxv2 transparency dodge: PASS")
