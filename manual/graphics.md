# Graphics

Location pictures and a title screen, drawn on the Next's Layer 2
picture layer.

## Where pictures go

Put your artwork in `IMAGES\`, named by DAAD picture number:
`001.png`, `002.png`, and so on. `BUILD.BAT` converts each one and
stages it in `RELEASE\` under the same number. Your game shows it with
the ordinary `PICTURE` and `DISPLAY` condacts - nothing about drawing a
picture is Next-specific.

`IMAGES\DAAD.png` is the exception: it is the title screen rather than a
numbered picture. See below.

## What the art must be

Every source PNG must be an **8-bit paletted (indexed) PNG**. Truecolour
images are rejected - quantize to an indexed palette in your paint
program before exporting.

The **width decides the shape**, and only two widths are accepted:

| Width | Becomes | On screen |
|---|---|---|
| **320** pixels | `NNN.NX2` | Full screen, border area included |
| **256** pixels | `NNN.NXI` | The classic paper area, inset by the border on every side |

Any other width stops the build with `expected a 320 or 256 wide PNG
named with a picture number`. The same message covers the other half of
the rule: the file name must contain a number, so `cellar.png` is
refused as surely as a 512-wide image is.

Height is free: up to 256 rows for 320-wide art, up to 192 rows for
256-wide art. A picture shorter than the full screen is drawn
**top-aligned**, and the screen below it stays transparent, so a text
window under the art shows through. That is the usual way to combine a
picture with a description.

If you are using 256-wide art, lay your text windows out the classic
way, inside the paper area - the picture occupies the middle of the
screen and leaves the border free.

Setting `COMPRESS=1` in `CONFIG.BAT` ZX0-compresses each converted
picture, which makes for a much smaller SD card image. The interpreter
decompresses on load, so nothing else changes.

## The classic bordered screen

256-wide art gives you the traditional Spectrum look - a picture sitting
in the paper area with a coloured surround around it. To lay your text
out to match, keep your windows inside the paper area of the 80x32 text
grid, which spans rows 4 to 27 and columns 8 to 71. `WINAT 4 8` with
`WINSIZE 24 64` is the whole classic screen.

`BORDER 0` to `BORDER 7` sets the surround, exactly as it always did.
What it colours here is everything outside the artwork and the text.
There is no classic border on this target - the text layer covers the
whole display, edge to edge, and the old ULA screen is switched off
underneath it - so the interpreter colours the area the picture and the
text do not reach instead. The result on screen is the one you expect.

320-wide art covers the border area as well, so `BORDER` only shows in a
game laid out the classic way.

## Text colours are never at risk

Text is drawn on its own layer with its own fixed palette. A picture's
palette only ever reaches Layer 2, so no artwork can recolour your
prose, however extreme its palette.

## Transparency

**Paint `#FF00FF` into palette slot 255. Those pixels are transparent**,
and the text layer shows through them.

That is what makes a full-screen picture with a hole in it possible: put
the hole where your text window will sit, and the picture frames the
text on all sides instead of sitting above it.

**The colour has to be in slot 255.** Only that slot is transparent. The
same magenta anywhere else in your palette comes out opaque, with
nothing on screen to tell you why, so if your hole renders as solid
magenta that is the first thing to check. Most editors let you set a
specific palette slot: in Aseprite you can edit the entry directly, and
in an indexed export from other tools you may need to reorder the colour
table so your transparent colour is last.

The build reports how many transparent pixels a converted picture has,
so you can confirm the hole is the size you intended.

**A picture with no slot-255 pixels is fully opaque**, which is the
normal case. A picture shorter than the full screen is drawn
top-aligned, and the screen below it stays transparent, so a text window
under the art shows through without your having to draw anything.

**Draw hole edges hard.** One flat colour, no anti-aliasing and no
dithering across the boundary. A soft edge leaves a fringe of
near-magenta pixels that are ordinary opaque colours, so the hole gets a
magenta halo instead of a clean edge.

**Near-saturated magenta elsewhere is altered slightly.** Any colour
that converts to the reserved value - red 238 or above, green 18 or
below, and blue 201 or above - is moved two steps down the blue scale as
the picture loads, so it stays opaque but comes out a slightly different
magenta than you painted. This exists so that a stray highlight cannot
punch a hole you did not ask for. If you want a hot magenta somewhere in
the artwork, moving any one channel out of that range is enough.

## Title screens

Ship `IMAGES\DAAD.png` and the game shows it at cold boot, over the
boot music if you have any, until a key is pressed. Then play begins as
normal. No source changes are needed, and a game with no title art boots
straight into play.

The art rules are identical to location pictures: 8-bit paletted PNG,
320 wide for full-screen or 256 wide for the classic bordered frame,
same `COMPRESS` handling. A game shipping a title screen does not print
its version stamp at boot, so the title is the first thing seen.

The title is shown once, at cold boot, and is never overridden per part
in a [multi-part game](multi-part-games.md).

## Already-converted artwork

If you have picture files that were converted elsewhere, put a
ready-made `DAAD.NX2` or `DAAD.NXI` (or a compressed variant) in the kit
folder itself, rather than in `IMAGES\`, and it is staged untouched. An
`IMAGES\DAAD.png` wins if you have both.

[Picture format](reference/picture-format.md) documents the file layout
itself - what the palette bytes mean, what the loader refuses, and which
ZX0 variant to compress with - for anyone writing a converter or paint
tool export.
