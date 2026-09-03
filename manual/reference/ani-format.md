# ANI format - animated sprite sets

What NextDAAD's sprite loader accepts, for anyone writing a packer,
exporter or editor plugin that emits these files instead of using the
kit's own. Authors working from `IMAGES\SPRITES\` never need any of this;
[Animated sprites](../sprites.md) is the page for that.

A file that breaks any rule here is refused rather than misrendered - a
rejected set simply does not appear, and the game carries on. Section 4
lists every refusal.

Files are named `NNN.ANI`, where `NNN` is the set number 0 to 254,
zero-padded to three digits. All multi-byte fields are little-endian.

---

## 1. Header

Sixteen bytes, at offset 0.

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | magic, `N` `A` |
| 2 | 1 | version, must be 1 |
| 3 | 1 | flags: bit 0 loop, bit 1 4-bit, all other bits 0 |
| 4 | 1 | W, cells wide, 1-8 |
| 5 | 1 | H, cells high, 1-8 |
| 6 | 2 | default X, 0-319 |
| 8 | 1 | default Y, 0-255 |
| 9 | 1 | frameCount, 1-255 |
| 10 | 1 | patternCount, 1-63 (8-bit) or 1-127 (4-bit) |
| 11 | 1 | blockCount, 1-15 for a 4-bit set, 0 for an 8-bit one |
| 12 | 2 | blockMask: 8-bit sets, bit `b` set if any opaque byte has top nibble `b`. 4-bit sets write 0 |
| 14 | 2 | tableLen, `frameCount x (1 + W x H)`, at most 1024 |

A cell is 16x16 pixels, so W and H give a frame of 16 to 128 pixels each
way. The default X and Y are picture pixels, converted to the sprite
plane by the interpreter; `GFX f 20` overrides both at the call.

`blockMask` is how the interpreter enforces the coexistence rule between
8-bit and 4-bit sets, so an 8-bit file must declare it honestly: a bit
for the top nibble of every opaque byte in the pattern data.

## 2. Body

Four parts, in this order, immediately after the header. Two of them are
present only in a 4-bit set.

**1. Frame table**, `tableLen` bytes. Per frame, one delay byte 1-255,
then `W x H` cell bytes in row-major order, cell 0 top-left. A cell byte
is a **set-relative pattern index**, 0 to `patternCount - 1`, or 255 for
a hidden cell that draws nothing.

**Cell 0 may never be 255.** It is the hardware anchor that every other
cell of the frame is positioned against, and an invisible anchor hides
the whole frame. A packer whose art needs an empty top-left cell must
emit a blank pattern and point cell 0 at it.

**2. Per-pattern block table**, 4-bit sets only, `patternCount` bytes.
Byte `p` is the set-relative palette block, 0 to `blockCount - 1`, that
pattern `p` draws with. The interpreter rewrites these into the actual
blocks it assigns at load, so the tick does no arithmetic.

**3. Block palettes**, 4-bit sets only, `blockCount x 32` bytes: for each
block, 16 entries of two bytes in the sprite palette's own order.

```
byte 0 : RRRGGGBB   the top 8 bits of a 9-bit colour
byte 1 : bit 0      the 9th (least significant) blue bit
```

**Entry 3 of every block is the transparent one.** The hardware compares
the pixel nibble against 3 and draws nothing when they match, so the
colour stored at entry 3 is never displayed. The kit writes `$E3`, 1
there for legibility.

**4. Pattern data**, `patternCount x 256` bytes for an 8-bit set or
`patternCount x 128` for a 4-bit one, in set-relative index order, pixels
row-major within each 16x16 cell.

- **8-bit**: one byte per pixel, RGB332, `$E3` transparent. Identical in
  shape and convention to `POINTER.SPR`.
- **4-bit**: two pixels per byte, **the left pixel in the high nibble**.
  That is the order `gfx2next` packs, and the order the sprite hardware
  reads.

## 3. Limits

| | |
|---|---|
| W, H | 1 to 8 cells, so 16 to 128 pixels |
| frameCount | 1 to 255 |
| patternCount | 1 to 63 (8-bit), 1 to 127 (4-bit) |
| blockCount | 1 to 15 (4-bit), exactly 0 (8-bit) |
| X | 0 to 319 |
| Y | 0 to 255 |
| tableLen | exactly `frameCount x (1 + W x H)`, at most 1024 |
| File size | under 18K, so a set never spans more than two 16K banks |

Two of those are worth a sentence each.

**The 1024-byte frame table is the ceiling most large sets meet first.**
It allows 15 frames at 128x128, 60 at 64x64, 204 at 32x32 and 255 - the
frame limit itself - at 16x16.

**`patternCount` is a file limit, not a run-time one.** Pattern storage
is 126 half-slots shared by every running set, after the pointer's. An
8-bit pattern takes an aligned pair of them and a 4-bit pattern takes
one, so 63 is the most any combination of 8-bit patterns can have live
and 126 the most 4-bit ones. A valid 127-pattern 4-bit file is therefore
one the loader will always refuse for want of space.

## 4. What the loader refuses

Every refusal leaves the game running and the screen unchanged: no set
starts, and any resource already taken for the attempt is given back. A
release build is silent. A DEBUG build prints `SPR? nn` in its marker
column, where `nn` is the hex reason code below.

| Code | Refusal |
|---|---|
| 02 | No free set record - eight sets are already running |
| 03 | Bad argument: set 255 given to `GFX n 19` or `GFX f 20`, or `GFX f 20` with `f` above 252 |
| 04 | No `NNN.ANI` in `PARTn\` and none in the root folder |
| 05 | Header rejected (the list below) |
| 06 | No free bank to hold the file image, even after evicting cached sets |
| 07 | Pattern half-slots exhausted |
| 08 | No contiguous run of `W x H` sprite slots left |
| 09 | Palette blocks exhausted - a 4-bit set could not claim `blockCount` free ones |
| 10 | Block conflict - an 8-bit set's `blockMask` overlaps blocks a 4-bit set has claimed |
| 11 | File length does not match the header, or the read failed |

Code 05 covers every header and table check:

- magic not `N` `A`, or version not 1
- any flags bit above bit 1 set
- W or H outside 1-8
- X above 319
- frameCount 0
- patternCount 0, above 63 for an 8-bit set, or above 127 for a 4-bit one
- blockCount not 1-15 for a 4-bit set, or not 0 for an 8-bit one
- tableLen not equal to `frameCount x (1 + W x H)`, or above 1024
- a cell byte that is neither 255 nor less than patternCount
- cell 0 equal to 255 in any frame
- a block-table byte not less than blockCount

Code 11 is the whole-file check: the header's own fields imply an exact
total size, and the file must be exactly that many bytes.
