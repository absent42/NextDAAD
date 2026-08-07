# Picture format - NX2 and NXI

What NextDAAD's location-graphics loader accepts, for anyone writing a
converter, exporter or paint-tool plugin that emits these files.

A file that breaks any rule here is refused by the loader rather than
misrendered - a rejected picture simply does not appear. Section 6 lists
what gets refused.

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
shifted two steps down the blue scale (still magenta, imperceptible in a
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

## 9. Verifying your output

`authoring-kit/lib/palcheck.ps1` audits a converted file's transparency.
It warns about a palette entry that collides with the reserved colour,
naming the index, and it reports how many pixels use index 255 - a count
rather than a warning, since deliberate transparency is legitimate:

```
powershell -File authoring-kit\lib\palcheck.ps1 path\to\001.NX2
```

It is advisory - it warns and exits 0, and it only understands
uncompressed files.
