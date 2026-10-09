# Picture format - NX2, NXI and NXP

What NextDAAD's location-graphics loader accepts, for anyone writing a
converter, exporter or paint-tool plugin that emits these files.

A file that breaks any rule here is refused by the loader rather than
misrendered - a rejected picture simply does not appear. Section 6 lists
what gets refused.

Sections 1 to 8 describe the whole-screen pictures, NX2 and NXI.
Section 9 describes NXP, the positioned picture: a rectangle of any
size that draws only its own area. It is a different file, with a
16-byte header in front.

---

## 1. The two shapes

| Extension | Width | Max height | Screen coverage |
|---|---|---|---|
| `.NX2` | **320** px | **256** rows | Full screen, border included |
| `.NXI` | **256** px | **192** rows | Classic paper area, inset by the border |

Width is implied by the extension. It is not stored in the file.

Files are named `NNN.NX2` / `NNN.NXI`, where `NNN` is the DAAD picture
number, zero-padded to three digits (`001`, `042`).

## 2. File layout

```
offset 0     : 512 bytes  palette   (256 entries x 2 bytes)
offset 512   : W*H bytes  pixel data (1 byte per pixel, row-major)
```

Nothing else. No header, no magic number, no footer, no padding.

**Height is derived from the file size**, as `(size - 512) / width`. The
file must therefore be exactly `512 + width * height` bytes.

## 3. Pixel data

One byte per pixel, each byte a palette index 0-255.

**Row-major, in both shapes** - `width` bytes for row 0, then row 1, and
so on. This holds for 320-wide too, even though its Layer 2 video memory
is column-major on the hardware; that is a property of the display
surface, not of this file. **Write rows.**

## 4. Palette entries

256 entries, 2 bytes each, in index order:

```
byte 0 : RRRGGGBB   the top 8 bits of a 9-bit colour
byte 1 : bit 0      the 9th (least significant) blue bit
         bit 7      Layer 2 priority (see below)
         bits 1-6   must be 0
```

So each colour is RGB333 - 3 bits per channel, 512 possible colours -
packed across two bytes. Byte 0 carries R(3) G(3) and the TOP TWO blue
bits; byte 1 bit 0 carries the remaining blue bit.

Converting 8-bit-per-channel source colour to byte 0:

```
byte0 = (r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6)
byte1 = (b >> 5) & 1
```

That truncation is the simpler choice - a mask and a shift, no table -
but it costs accuracy: it can leave a channel up to 31 away from the
source value on a 0-255 scale, where rounding to the nearest of the
eight levels 0, 36, 73, 109, 146, 182, 219, 255 is never more than 18
out, and it sends a wider band of near-magenta onto the reserved value
(section 5).

**Priority bit.** Bit 7 of byte 1 marks a colour as always-on-top,
above all other layers regardless of layer ordering. NextDAAD passes it
through unchanged, so you may set it deliberately - but leave it 0
unless you mean it, and never set it on the reserved entry below.

**A full 512-byte palette is required even if the art uses fewer
colours.** Pad unused entries with zeros.

## 5. Reserved: one index and one colour

### Index 255 is reserved

The interpreter stamps palette entry 255 with the transparent colour on
every picture load. **Any pixel drawn with index 255 becomes a hole**
showing the text layer beneath.

Quantise the **opaque** artwork into **indices 0-254** - 255 colours,
not 256. Index 255 is emitted deliberately, for transparent pixels, or
not at all. An exporter with no transparency to write must therefore
leave it unused: a plain 256-colour quantisation puts stray pixels on it
and every one of them is a hole.

An exporter that wants to emit transparency puts the author's transparent
colour in slot 255 and writes index 255 for those pixels. The colour in
slot 255 is overwritten on load, so its value does not matter to the
result; `#FF00FF` is the convention because it matches the sprite path
and previews as obvious magenta in an editor.

### Byte 0 = `$E3` is reserved

The Spectrum Next's global transparency colour is the RGB332 value
`$E3` - full red, no green, and both top bits of the blue field set. It
is what the hardware register holds after a reset, and the same colour
Next sprites use.

**No palette entry may carry byte 0 = `$E3`, except index 255.** That is
the whole rule, and it is exact.

**Transparency is a COLOUR compare, not an index compare.** The hardware
matches byte 0 of a palette entry and nothing else. Two consequences:

1. **Both 9-bit colours whose byte 0 is `$E3` are transparent** - the
   display colours (255, 0, 219) and (255, 0, 255) - whatever index they
   sit at. The 9th blue bit cannot rescue an entry.
2. **Which 24-bit source colours reach `$E3` depends on your own channel
   conversion**, so test byte 0 after converting rather than screening
   RGB888 values beforehand. The truncating conversion in section 4
   sends everything with `r` 224-255, `g` 0-31, `b` 192-255 to `$E3`.
   Rounding each channel to the nearest of the eight levels 0, 36, 73,
   109, 146, 182, 219, 255 - the more faithful conversion, and the one
   Gfx2Next performs - narrows that to `r` 238-255, `g` 0-18, `b`
   201-255. Note which side `#E000C0` (224, 0, 192) falls: caught by the
   first, safe under the second. It is the naive left-justified
   expansion of `$E3`, not a colour on the display lattice.

NextDAAD defends against this - an art entry whose byte 0 is `$E3` is
shifted one step up the green scale (still magenta, imperceptible in a
picture) so a deliberate magenta renders rather than punching a hole.
**But do not rely on that**: it alters the author's colour silently.

## 6. What the loader REFUSES

A file failing any of these is rejected, and the picture does not
display. It is never misrendered.

- Smaller than 512 bytes (no complete palette).
- Exactly 512 bytes (no pixel data).
- `(size - 512)` not an exact multiple of the width - a partial trailing
  row.
- More than 192 rows for a 256-wide file.
- More than 256 rows for a 320-wide file.

## 7. Optional ZX0 compression

Pictures may be ZX0-compressed. The interpreter decompresses on load.

**Use ZX0 CLASSIC (v1) format, not v2.** The two are mutually
unreadable and a ZX0 stream carries no version marker, so a v2 file
fails silently or renders as garbage. Compressors predating ZX0 v2 emit
v1 unconditionally; a v2-capable compressor needs its `-c` (classic)
switch.

The compressed bytes must decompress to exactly the layout in section 2.

Extensions, tried in this order (compressed wins over raw):

| Order | Name | Shape |
|---|---|---|
| 1 | `NNN.NX2.ZX0` | 320, compressed |
| 2 | `NNN.N2Z` | 320, compressed (8.3 synonym) |
| 3 | `NNN.NX2` | 320, raw |
| 4 | `NNN.NXI.ZX0` | 256, compressed |
| 5 | `NNN.NXZ` | 256, compressed (8.3 synonym) |
| 6 | `NNN.NXI` | 256, raw |

The double extension is what Gfx2Next emits; the three-letter synonyms
exist for plain-FAT setups without long filenames. Either works.

## 8. Checklist for an exporter

- [ ] Quantise opaque artwork into **indices 0-254** (255 colours, not
      256). Emit pixel index 255 only where you mean transparency, and
      not at all otherwise.
- [ ] Transparent pixels, if any, use index 255 and no other index.
- [ ] Never emit byte 0 = `$E3` except at index 255 - test after your
      channel conversion, not before it.
- [ ] Write **512 bytes** of palette, padded, even for a small palette.
- [ ] Pack each entry as `byte0 = (r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6)`,
      `byte1 = (b >> 5) & 1`, byte 1 bits 1-7 zero - the simple
      truncating conversion, with the accuracy cost noted in section 4.
- [ ] Write pixels **row-major**, `width` bytes per row.
- [ ] Total size exactly `512 + width * height`.
- [ ] Height within 192 (256-wide) or 256 (320-wide).
- [ ] If compressing, **ZX0 v1 classic**.
- [ ] Name it `NNN.NX2` or `NNN.NXI`.
- [ ] Positioned: write the 16-byte NXP header first; never compress it.

## 9. NXP - positioned pictures

An NXP picture is placed on the screen at a position, instead of
replacing the whole screen. It carries its own size, its position and
the range of palette entries it is allowed to change. Everything after
the 16-byte header is exactly what a whole-screen picture holds.

### Layout

```
offset 0  : 16 bytes   header
offset 16 : 512 bytes  palette (256 entries x 2 bytes, as section 4)
offset 528: W*H bytes  pixels (1 byte per pixel, row-major, as section 3)
```

The header, all multi-byte values little-endian:

| Offset | Size | Field |
|---|---|---|
| 0 | 3 | magic `NXP` (ASCII `4E 58 50`) |
| 3 | 1 | version, 1 |
| 4 | 1 | mode: 0 = 256x192 coordinate space, 1 = 320x256 |
| 5 | 1 | flags: bit 0 = floating (X and Y are ignored); bits 1-7 zero |
| 6 | 2 | X in pixels |
| 8 | 1 | Y in pixels |
| 9 | 2 | width in pixels |
| 11 | 1 | height in pixels, 0 means 256 |
| 12 | 1 | palette first |
| 13 | 1 | palette last; first greater than last means apply no palette |
| 14 | 2 | reserved, zero |

Mode 0 coordinates are the classic 256x192 area, as an NXI picture
covers it. Mode 1 coordinates are the full 320x256 screen, as an NX2
picture covers it. A game uses one mode throughout.

### Rules for the writer

- Width 1 to 256 (mode 0) or 1 to 320 (mode 1). Height 1 to 192 (mode 0)
  or 1 to 256 (mode 1).
- A fixed picture must fit: X plus width within the screen width, Y plus
  height within the screen height. A floating picture must fit the
  screen in size only. (A fixed picture that does overhang is clipped to
  the screen when drawn, not refused, but do not rely on it.)
- A raw file is exactly 16 + 512 + width x height bytes.
- Index 255 is the transparent index and byte 0 = `$E3` is reserved, the
  same as in section 5. A pixel of 255 is a hole, and it is written like
  any other pixel, so it replaces whatever art was underneath.
- There is no palette shift and no re-indexing: pixel value N uses palette
  entry N. Only entries first to last of the file's palette are
  loaded when the picture draws, so keep the picture's pixels inside that
  range.
- Floating pictures use X and Y of 0 in the header; the game's current
  text window decides where they land.

### Compression

The header is never compressed. Bytes 16 onward are the ZX0 stream(s)
exactly as for NX2 and NXI (section 7: ZX0 classic, decompressing to the
512-byte palette followed by the pixels).

### Extensions

Tried in this order, before any of the section 7 rows:

| Order | Name | Shape |
|---|---|---|
| 1 | `NNN.NXP.ZX0` | positioned, compressed |
| 2 | `NNN.NPZ` | positioned, compressed (8.3 synonym) |
| 3 | `NNN.NXP` | positioned, raw |
| 4-9 | the NX2 and NXI rows of section 7 | whole screen |

The mode comes from the header, not the extension. A picture whose mode
differs from the screen's switches the screen: the Layer 2 surfaces are
cleared and the mode changes before the picture draws. While the game is
drawing off-screen (`GFX n 4`) a picture of the other mode is skipped
instead, because the hidden surface cannot change mode on its own.

### Worked examples

A fixed picture, 256 wide, 96 high, at 0,0 in mode 0, using palette
entries 0 to 100:

```
4E 58 50 01  00  00  00 00  00  00 01  60  00 64  00 00
magic    ver mode flg X     Y   W      H   first last reserved
```

Here the 256 wide is `00 01` (256 = `$0100`), 96 high is `60`, and the
palette range is `00` to `64` (100). The file is 16 + 512 + 256 x 96 =
25104 bytes raw.

A floating picture, 64 wide, 32 high, mode 0, applying no palette (first
1, last 0):

```
4E 58 50 01  00  01  00 00  00  40 00  20  01 00  00 00
```

The flag byte is 1 (floating), X and Y are zero, width is `40 00` (64),
height is `20` (32), and palette first 1 greater than last 0 means the
picture changes no palette entry. The file is 16 + 512 + 64 x 32 = 2576
bytes raw.

## 10. Verifying your output

`authoring-kit/lib/palcheck.ps1` audits a converted file's transparency.
It warns about a palette entry that collides with the reserved colour,
naming the index, and it reports how many pixels use index 255 - a count
rather than a warning, since deliberate transparency is legitimate:

```
powershell -File authoring-kit\lib\palcheck.ps1 path\to\001.NX2
```

For an NXP file it reads past the header and also counts pixels that use
a palette index outside the picture's declared range. Those pixels
would draw with whatever colour the last picture left in that entry.

It is advisory - it warns and exits 0, and it only understands
uncompressed files.
