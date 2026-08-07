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

## Text colours are never at risk

Text is drawn on its own layer with its own fixed palette. A picture's
palette only ever reaches Layer 2, so no artwork can recolour your
prose, however extreme its palette.

## Transparency: keep magenta out of your artwork

One palette slot is reserved so pictures can let text show through, and
one colour is reserved alongside it. Both are yours to work around - the
kit converts the PNG you supply and never recolours or re-quantizes it
for you.

**Do not paint with `#E000C0`** (224, 0, 192), the Spectrum Next's
standard transparency magenta. It will not come out the colour you
painted: as it loads a picture, the interpreter moves every palette
entry of that colour two steps down the blue scale, so those pixels
render as a slightly different magenta. They stay opaque - the shift is
what stops them becoming holes - but it happens silently, and it catches
near neighbours of that colour too: anything with red 224 or above,
green below 32, and blue 192 or above lands on the same hardware value.
Magenta is the conventional chroma-key colour, so most palettes steer
clear of it naturally. If you do want magenta in a picture, pick one a
shade or two away and it ships exactly as painted.

**Quantize to 255 colours, indices 0-254.** Palette slot 255 is
reserved for the transparent entry and is overwritten on every picture
load, so any pixel drawn with it becomes a hole. Most paint programs let
you set the palette size directly when exporting an indexed PNG.

**The check warns, it never fails.** The build audits each converted
picture and prints a warning naming the file and the offending palette
index if it finds either hazard. It does not stop, because a deliberate
transparent area is a perfectly good reason to have one.

Two things it cannot audit:

- anything built with `COMPRESS=1` - a compressed file has no readable
  palette, so a compressed build produces no transparency warnings at
  all, and
- ready-made title art supplied already compressed.

If you want the check on art you normally ship compressed, run one build
with `COMPRESS=0` and read the warnings.

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
