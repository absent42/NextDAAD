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
    # A gradient sweep that never packs to $E3 must come out of the
    # dodge byte-for-byte identical to the undodged naive pack - the
    # branch in build_palette_block must not fire for entries it has
    # no business touching. r == g throughout keeps every entry out of
    # the collision block (r in 224-255 AND g in 0-31 AND b in 192-255,
    # the near-magenta region byte0 == $E3 packs from) - verified by
    # direct sweep, not assumed: no i in range(256) collides.
    pal = np.zeros((256, 3), dtype=int)
    for i in range(256):
        pal[i] = (i, i, (i * 3) % 256)
    dodged = nxv2enc.build_palette_block(pal)
    naive = bytearray(len(dodged))
    for i in range(256):
        r, g, b = (int(pal[i, 0]), int(pal[i, 1]), int(pal[i, 2]))
        naive[i * 2] = (r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6)
        naive[i * 2 + 1] = (b >> 5) & 1
    assert dodged == bytes(naive)
    # Spot-check that a mid-grey packs where it always did.
    pal2 = np.zeros((256, 3), dtype=int)
    pal2[0] = (128, 128, 128)
    b = nxv2enc.build_palette_block(pal2)
    assert b[0] == ((128 & 0xE0) | ((128 >> 3) & 0x1C) | (128 >> 6))

if __name__ == "__main__":
    test_no_entry_carries_the_transparent_colour()
    test_ordinary_colours_are_untouched()
    print("nxv2 transparency dodge: PASS")
