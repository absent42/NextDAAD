# Customising

Two things you can replace without touching your source: the text font
and the mouse pointer. Each can be one or more files dropped into the
kit folder, staged to the release untouched. The base file of each is
picked up automatically at boot; up to nine further numbered variants of
each can be switched from your source while the game runs.

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
`.ch8` files font collections ship).

Drop a `FONT.ch8` (or `FONT1.ch8` to `FONT9.ch8`, for the numbered fonts
below) in the kit folder and the kit build converts it for you -
nothing to run by hand. A ready-made `.CHR` of the same number still
wins over a converted `.ch8`, so a hand-built full table always takes
priority.

Working outside the kit, or converting a `.ch8` kept somewhere else,
`lib\fontconv.ps1` turns one into a `FONT.CHR` directly:

```
powershell -ExecutionPolicy Bypass -File lib\fontconv.ps1 -In MyFont.ch8 -Out FONT.CHR
```

(The `-ExecutionPolicy Bypass -File` part is needed because PowerShell
refuses to run a bare script file by default.)

It accepts either shape. A 2048-byte input is copied straight through. A
768-byte input is padded into a full table: your glyphs fill 32 to 127,
and every other glyph keeps `lib\default.chr` - a copy of the built-in
font - unless `-Base <file>` names a 2048-byte font of your own to pad
against instead. That is how a second font keeps the first one's UDGs or
accented characters: convert the first `.ch8` normally, then convert the
second with `-Base` pointing at the `FONT.CHR` the first conversion
produced, and glyphs 0-31 and 128-255 carry over instead of reverting to
the built-in font. The kit build's own automatic `.ch8` conversion above
never passes `-Base` - it always pads against the built-in font - so
this only applies when you run `fontconv.ps1` yourself. Any other input
size is an error naming both shapes it accepts.

Put the resulting `FONT.CHR` (or `FONT1.CHR` to `FONT9.CHR`) in the kit
folder to ship it.

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

### Numbered fonts and switching at runtime

`FONT.CHR` is font 0, the base. Nine more can sit beside it in the kit
folder: `FONT1.CHR` to `FONT9.CHR` (ready-made, or converted from
`FONT1.ch8` to `FONT9.ch8` as above). Nothing on disk selects one - `GFX
n 16` in your source installs font `n` while the game runs. `GFX 3 16`
switches to `FONT3.CHR`; `GFX 0 16` returns to the base. A missing or
wrong-size file is a silent no-op: whatever font is currently installed
stays, and the game plays on.

A font switch **restyles every character already on screen**, instantly
and with no redraw, because the hardware reads the glyph table live.
That is a feature, not a caveat - but if you expect only text printed
*after* the switch to change, the whole screen changing at once will
surprise you.

### Per-part and multi-font

In a [multi-part game](multi-part-games.md), a `PART<n>\FONT.CHR` (and
likewise `PART<n>\FONT1.CHR` to `PART<n>\FONT9.CHR`) gives that part its
own font, falling back to the root file of the same number if the part
ships none. It is staged with the rest of that part's assets - there is
nothing to configure.

A part switch reinstalls the base font: it re-probes for `FONT.CHR`
(per-part, then root) the moment the new part loads. A game that wants a
numbered font after a part switch re-selects it with `GFX n 16`.

That re-probe is not quite the same guarantee `GFX 0 16` gives, and the
difference is worth knowing plainly. `GFX 0 16` lays the interpreter's
embedded glyph table down FIRST and only then looks for `FONT.CHR`, so
it always ends up somewhere known - `FONT.CHR` if one exists, the
embedded table if not. A part switch skips that first step and only
looks for `FONT.CHR`. If neither the new part nor the root ships one,
nothing reverts: the glyph table stays exactly what it was before the
switch, which may be a numbered font selected earlier in the previous
part. "0 is the base" reads the same in both places; only `GFX 0 16` is
guaranteed to reach a known font.

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

### Numbered pointer shapes

`POINTER.SPR` is shape 0, the base. Nine more can sit beside it in the
kit folder: `POINTER1.SPR` to `POINTER9.SPR`. `MOUSE n 5` (`POINTERMS`)
installs shape `n` and re-arms hardware sprite slot 0: `MOUSE 3 5`
switches to `POINTER3.SPR`; `MOUSE 0 5` returns to the base. It lays the
built-in arrow down first and only then looks for `POINTER.SPR`, so
shape 0 always reaches a known shape even after a numbered shape has
replaced it - `POINTER.SPR` if your game ships one, the built-in arrow
if it does not. A missing or wrong-size file is a silent no-op: whatever
shape is currently installed stays, and the game plays on.

The hotspot set by `MOUSE 6` (`DELTAXMS`) and `MOUSE 7` (`DELTAYMS`) is
**unchanged by a shape switch** - it stays wherever you last put it. If
a new shape needs a different hotspot, set it again after selecting the
shape.

### Making one

Any sprite, tile or hex editor that can export a flat unheadered 16x16
8-bit byte dump will do. Draw against the Next's standard RGB332
palette, where slot N previews as colour N, so the indices you export
are already the correct output bytes. Then save exactly 256 bytes as
`POINTER.SPR`.

Gfx2Next can produce this file directly from a 16x16 indexed PNG:

```
gfx2next -sprites -pal-std -pal-none pointer.png POINTER.SPR
```

Gfx2Next forces a lowercase extension on the output whatever name you
give it, so that lands as `POINTER.spr` and you rename it - which is all
the kit's own build does after converting a PNG. It only matters
cosmetically: Windows, FAT and esxDOS all match the name regardless of
case, so the interpreter finds `POINTER.spr` just as happily.

Paint `#FF00FF` for the transparent pixels and `-pal-std` converts them
to the transparent value. Here it is the **colour** that decides, and
the palette slot it sits in does not matter - the reverse of a Layer 2
picture, where transparency comes from slot 255 and the colour in that
slot is irrelevant. Black and white come out as the same bytes the
default arrow uses.

`-pal-std` is what makes this work - it converts your colours to the
Next's standard palette, which is the one the pointer is displayed
against. Without it Gfx2Next builds its own palette and emits indices
into it, and since nothing loads that palette the pointer comes out in
the wrong colours while still being exactly 256 bytes and passing every
check.

The kit build does this for you: drop a 16x16 indexed PNG at
`IMAGES\POINTER.png` (or `IMAGES\POINTER1.png` to `IMAGES\POINTER9.png`,
for the numbered shapes above) and the build converts and stages it
automatically. The command above is for converting a pointer by hand,
outside the kit. Either way, a ready-made `.SPR` in the kit folder wins
over a converted PNG of the same number, so keep only one source per
shape.

### Exporting from a sprite editor

Sprite editors often have a Next export script - Aseprite's is the one
most people use. These write one byte per pixel, and that byte is the
pixel's **palette index**. They write nothing else: no palette file, and
no transparency handling.

That is the right format, but only if two things are true of the file
you are exporting, and neither is true by default.

**Your editor's palette must be the Next standard palette**, the one
where slot N holds RGB332 colour N. This interpreter never loads a
sprite palette, so the hardware reads each exported byte as a colour
directly. If you draw against your editor's own palette, an index of 255
does not mean "whatever I put in slot 255", it means colour 255, which is
white.

**Transparency has to be painted, not alpha.** An alpha channel does not
survive the export: the script reads each pixel's index and ignores its
opacity, so a background you left transparent comes out as an ordinary
opaque colour. Paint it in **slot 227** instead, which is `$E3`, the
transparent value.

Get either wrong and the symptom is the same, and it is a quiet one: a
file that is exactly 256 bytes, passes every size check the kit and the
interpreter apply, and renders as a solid block of the wrong colour with
your artwork somewhere inside it. Nothing reports an error, because
nothing can tell a wrong colour from an intended one.

If loading the Next standard palette into your editor is awkward, use
the PNG route above instead. Export an ordinary PNG with `#FF00FF` for
the transparent pixels and let `-pal-std` do the mapping for you; that
path cares about the colours you drew, not the slots they sit in.

### Per-part pointers

As with fonts, a `PART<n>\POINTER.SPR` (and likewise
`PART<n>\POINTER1.SPR` to `PART<n>\POINTER9.SPR`) in a [multi-part
game](multi-part-games.md) overrides the root pointer of the same
number for that part only, falling back to the root file if the part
ships none.

A part switch reinstalls the base pointer the same way it reinstalls the
base font (see [Custom fonts](#custom-fonts) above): it re-probes for
`POINTER.SPR` without first restoring the built-in arrow. If neither the
new part nor the root ships one, whatever shape was active stays active
rather than reverting - only `MOUSE 0 5` is guaranteed to reach a known
shape. A game that wants a numbered shape after a part switch re-selects
it with `MOUSE n 5`.

`MOUSE n 5` (`POINTERMS`) is the shape switch described above: it
re-uploads the chosen pattern into hardware sprite slot 0 and re-arms
it, every time, even when the shape requested is already the one
installed - so the documented `POINTERMS` then `SHOWMS` sequence always
leaves slot 0 holding your pointer, whatever else used the slot in
between.

## Text and border colour

`INK n`, `PAPER n` and `BORDER n` take any value from 0 to 255. The
compiler already checks all three against that full range - they are
declared as a generic value parameter, not a colour-specific one - so
nothing needed to change there; only what the interpreter does with the
upper part of the range is new.

**0 to 15 are the classic Spectrum colours**, unchanged: 0 to 7 are the
eight ULA colours in the usual `INK`/`PAPER` order, and 8 to 15 are the
same eight again, bright.

**16 to 255 are the standard Next colour of that same number** - the
`RRRGGGBB` byte convention already used for [location
art](graphics.md) and Gfx2Next: bits 7-5 are red, bits 4-2 are green,
and bits 1-0 are blue. It is one mental model for pictures and text
alike - whatever a number means to Gfx2Next, it means the same thing
here.

There is no palette file to supply, and none is needed. Every one of
the 256 standard Next colours is already addressable by its own number,
so `INK`, `PAPER` and `BORDER` simply reach further into the same fixed
palette [location art](graphics.md) draws from - there is nothing to
load, generate or ship alongside your database.

### Working out a colour from its number

For any `n` from 16 to 255:

```
red   = (n >> 5) & 7      -- 0-7
green = (n >> 2) & 7      -- 0-7
blue  =  n       & 3      -- 0-3
```

or build a number from the three components the other way round:

```
n = red*32 + green*4 + blue
```

A few worked examples: 224 is full red (`7,0,0`), 28 is full green
(`0,7,0`), and 255 is white (`7,7,3`, the maximum of everything). 3
works out to pure blue by the same arithmetic, but 3 is inside 0 to 15,
so it reads as the classic colour it already was rather than as blue -
every value below 16 keeps its classic meaning regardless of what the
`RRRGGGBB` arithmetic would say about that same byte; only 16 and above
are decoded this way.

Because blue only has two bits, the same thing is true of every pure
blue: with red and green both 0, the value never climbs past 3, so a
saturated blue with no red or green in it is always a classic colour
(1, or 9 for bright), never one from the extended range. Add a touch of
red or green and the value moves above 15, with a matching shift in the
resulting hue.

If you would rather see the numbers than compute them, any paint or
sprite tool that lets you pick from the Next's standard RGB332 palette
- the same one described under [Custom mouse
pointer](#custom-mouse-pointer) above - previews colour `n` at index
`n` directly, since it is the identical 256-colour palette `INK`,
`PAPER` and `BORDER` draw from.
