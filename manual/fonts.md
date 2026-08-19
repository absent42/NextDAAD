# Fonts

A custom font is a `FONT.CHR` file dropped into the kit folder - not in
`IMAGES\` - staged to the release untouched and installed in place of
the built-in font at boot. Up to nine further numbered variants can sit
beside it and be switched from your source while the game runs.

Custom fonts are optional. With no `FONT.CHR` the built-in font plays.

## The format

`FONT.CHR` is **256 glyphs, 8 rows each, 1 bit per pixel - exactly 2048
bytes**. That is the plain raw charset format the DAAD and ZX tool
ecosystem emits, so output from CH82CHR, jDAADFontMaker, GCS and similar
font editors works directly, unmodified.

A file of any other size is rejected at boot and the built-in font plays
instead. Nothing about your game changes; the text simply looks as it
always did.

## Classic 768-byte charsets

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

## Which glyphs actually get drawn

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

## Glyph 32 must stay blank

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

## Numbered fonts and switching at runtime

`FONT.CHR` is font 0, the base. Nine more can sit beside it in the kit
folder: `FONT1.CHR` to `FONT9.CHR` (ready-made, or converted from
`FONT1.ch8` to `FONT9.ch8` as above). Nothing on disk selects one - `GFX n 16` in your
source installs font `n` while the game runs. `GFX 3 16` switches to
`FONT3.CHR`; `GFX 0 16` returns to the base. A missing or wrong-size
file is a silent no-op: whatever font is currently installed stays, and
the game plays on.

A font switch **restyles every character already on screen**, instantly
and with no redraw, because the hardware reads the glyph table live.
That is a feature, not a caveat - but if you expect only text printed
*after* the switch to change, the whole screen changing at once will
surprise you.

## Per-part and multi-font

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
