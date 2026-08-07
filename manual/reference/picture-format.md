# Picture format - NX2 and NXI

What NextDAAD's location-graphics loader accepts, for anyone writing a
converter, exporter or paint-tool plugin that emits these files.

Every statement here was verified against the interpreter's own loader
(`src/overlay2.asm`) rather than transcribed from an older document.
Where the loader REFUSES a file, that is called out - it refuses rather
than misrendering, so a rejected picture simply does not appear.

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
so on. This is worth stating plainly because the Layer 2 *video memory*
for 320-wide mode is column-major, and the interpreter's own internals
describe it that way; that is a property of the hardware surface, not of
this file. **The loader performs the scatter. Write rows.**

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

Quantise to **255 colours (indices 0-254)**, not 256.

### The colour #E000C0 is reserved

The Spectrum Next's global transparency colour is magenta - 24-bit
**`#E000C0`** (224, 0, 192), which packs to byte 0 = `$E3`. It is the
value the hardware register holds after a reset, and the same colour
Next sprites use.

**Transparency is a COLOUR compare, not an index compare.** The hardware
matches the top 8 bits of a palette entry - byte 0 only - against that
value. Two consequences:

1. **Both 9-bit colours sharing byte 0 = `$E3` are transparent**, whatever
   index they sit at. The 9th blue bit cannot rescue an entry.
2. **A whole region of near-magenta collides**, not just the exact
   triple: any colour with `r` in 224-255, `g` in 0-31, `b` in 192-255
   packs to `$E3`.

NextDAAD defends against this - an art entry whose byte 0 is `$E3` is
shifted two steps down the blue scale (still magenta, imperceptible in a
picture) so a deliberate magenta renders rather than punching a hole.
**But do not rely on that**: it alters the author's colour silently. Keep
`#E000C0` and its near neighbours out of the palette.

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

- [ ] Quantise to at most **255** colours; never emit pixel index 255.
- [ ] Keep `#E000C0` (224, 0, 192) and near-magenta out of the palette.
- [ ] Write **512 bytes** of palette, padded, even for a small palette.
- [ ] Pack each entry as `byte0 = (r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6)`,
      `byte1 = (b >> 5) & 1`, byte 1 bits 1-7 zero.
- [ ] Write pixels **row-major**, `width` bytes per row.
- [ ] Total size exactly `512 + width * height`.
- [ ] Height within 192 (256-wide) or 256 (320-wide).
- [ ] If compressing, **ZX0 v1 classic**.
- [ ] Name it `NNN.NX2` or `NNN.NXI`.

## 9. Verifying your output

`authoring-kit/lib/palcheck.ps1` audits a converted file for the two
transparency hazards and reports which palette index offends:

```
powershell -File authoring-kit\lib\palcheck.ps1 path\to\001.NX2
```

It is advisory - it warns and exits 0, and it only understands
uncompressed files.
