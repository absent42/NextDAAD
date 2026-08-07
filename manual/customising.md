# Customising

Two things you can replace without touching your source: the text font
and the mouse pointer. Both are single files dropped into the kit
folder, staged to the release untouched, and picked up by the
interpreter at boot.

Neither is required. With no `FONT.CHR` the built-in font plays; with no
`POINTER.SPR` the default arrow plays.

## Custom fonts

Put a `FONT.CHR` in the kit folder - not in `IMAGES\` - and the
interpreter installs it in place of its own font. The file is copied
into the glyph table byte for byte, with no conversion of any kind, so
what you put in the file is exactly what appears on screen.

### The format

`FONT.CHR` is **256 glyphs, 8 rows each, 1 bit per pixel - exactly 2048
bytes**. That is the plain raw charset format the DAAD and ZX tool
ecosystem emits, so output from CH82CHR, jDAADFontMaker, GCS and similar
font editors works directly, unmodified.

A file of any other size is rejected at boot and the built-in font plays
instead. Nothing about your game changes; the text simply looks as it
always did.

### Classic 768-byte charsets

Most ZX font packs and editors export the older shape instead:
characters 32 to 127 only, 96 glyphs of 8 rows, **768 bytes** (the
`.ch8` files font collections ship). `lib\fontconv.ps1` turns one into a
`FONT.CHR`:

```
powershell -ExecutionPolicy Bypass -File lib\fontconv.ps1 -In MyFont.ch8 -Out FONT.CHR
```

(The `-ExecutionPolicy Bypass -File` part is needed because PowerShell
refuses to run a bare script file by default.)

It accepts either shape. A 2048-byte input is copied straight through. A
768-byte input is padded into a full table: your glyphs fill 32 to 127,
and every other glyph keeps the built-in font's original. Any other size
is an error naming both shapes it accepts.

Put the resulting `FONT.CHR` in the kit folder to ship it.

### Which glyphs actually get drawn

The whole 256-glyph table is addressable, but ordinary game text only
ever reaches part of it:

- **Printed characters 32 to 127** - ordinary printable text - select
  glyphs 32 to 127.
- **The same characters select glyphs 160 to 255 instead** (glyph =
  character + 128) when a window is set to the upper charset, or while
  the `GFX ON` / `GFX OFF` print escape is active. That is a mirrored
  bold or alternate face you can reach without duplicating any
  vocabulary.
- **Characters 16 to 31 and 128 to 255** select their matching glyph
  directly, with no mirroring - the extended and graphics glyphs.

In practice a 768-byte classic charset covers everything a typical DAAD
game prints. Glyphs 16 to 31, 128 to 159 and 160 to 255 are reachable
only through the routes above, and keep the built-in font's originals
unless your `FONT.CHR` supplies the full 2048 bytes. **Glyphs 0 to 15 no
print path reaches at all** - a `FONT.CHR` may define them, but nothing
will ever draw them.

### Glyph 32 must stay blank

Every cell the engine blanks - an untouched area, a row scrolled in,
anything not yet printed - is filled with glyph 32 at the ordinary
default attribute: black paper, white ink, the same attribute a printed
cell uses.

So a glyph 32 with any non-zero pixels **draws those pixels in the ink
colour**. The result is white specks scattered across every blank part
of the screen instead of clean black paper. Leave glyph 32 empty unless
you genuinely want that.

`fontconv.ps1` warns - it does not refuse - when the font you hand it
has a non-blank glyph 32, for either input shape. A `FONT.CHR` you place
in the kit folder without running it through `fontconv.ps1` is never
checked, so check that one yourself if you have edited glyph 32.

### Per-part and multi-font

In a [multi-part game](multi-part-games.md), a `PART<n>\FONT.CHR` gives
that part its own font, falling back to the root `FONT.CHR` (or the
built-in font) if the part ships none. It is staged with the rest of
that part's assets - there is nothing to configure.

Only `FONT.CHR` is ever read. A `FONT2.CHR` or similar in the kit folder
or on the card is inert.

## Custom mouse pointer

Put a `POINTER.SPR` in the kit folder and the interpreter installs it
into hardware sprite slot 0 in place of the default arrow. The next
`MOUSE 1` (`SHOWMS`) in your game picks it up automatically; no source
changes are needed.

### The format

`POINTER.SPR` is a **raw 16x16 sprite pattern, 8 bits per pixel -
exactly 256 bytes**. One byte per pixel, row-major (row 0 first, 16
bytes per row), no header, no palette, no padding.

Any other size is rejected at boot and the default arrow plays instead.

### Colour values

Each byte is read by the sprite hardware as an **RGB332 colour
directly** - index N is colour N. So the byte you write is the colour
that appears; there is no pointer palette to load or match.

- **`$E3` is transparent.** Use it for every pixel that should show the
  background through. A 16x16 pointer is mostly this value.
- **`$00`** is black and **`$FF`** is white - what the default arrow
  uses for its outline and its fill. Any other byte value is a valid
  opaque colour.

The **hotspot is pixel (0,0)**, the pattern's top-left corner, so draw
the business end of your pointer there. `MOUSE 6` and `MOUSE 7` shift
the hotspot within the bitmap if you want it elsewhere - see
[Symbols](reference/symbols.md).

### Making one

Any sprite, tile or hex editor that can export a flat unheadered 16x16
8-bit byte dump will do. Draw against the Next's standard RGB332
palette, where slot N previews as colour N, so the indices you export
are already the correct output bytes. Then save exactly 256 bytes as
`POINTER.SPR`.

Gfx2Next's sprite mode does emit this exact raw format for a 16x16
indexed PNG, but it is deliberately not wired into the build: it only
comes out right if the source PNG's palette was authored with index N
already equal to RGB332 colour N. A normal "quantize to a nice-looking
palette" export - the workflow location art uses - silently produces the
wrong pointer colours. Use it only if you have set up that identity
palette on purpose; otherwise build the file in a sprite or hex editor.

### Per-part pointers

As with fonts, a `PART<n>\POINTER.SPR` in a
[multi-part game](multi-part-games.md) overrides the root pointer for
that part only, and falls back to the root pointer (or the default
arrow) if the part ships none.

`MOUSE 5` (`POINTERMS`) re-uploads the pointer pattern into sprite slot
0 and re-arms it. There is only one pointer shape on this target, so its
parameter selects nothing; what it guarantees is that the documented
`POINTERMS` then `SHOWMS` sequence always leaves slot 0 holding your
pointer, whatever else used the slot in between.
