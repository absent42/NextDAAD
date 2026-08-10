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
images are rejected - quantize to an indexed palette before exporting,
either in your paint program or with [NextDither](#nextdither), which
does it for this target specifically.

**Quantize to 255 colours, indices 0-254.** Palette slot 255 is
reserved: pixels drawn with it become transparent holes. Leaving it
unused is what keeps a picture fully opaque, and it is the setting you
want unless you are deliberately putting a hole in the art - see
[Transparency](#transparency) below. Most paint programs let you set the
palette size directly when exporting an indexed PNG; a plain 256-colour
export can scatter a few pixels onto slot 255 without your noticing.

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
window under the art shows through without your having to draw anything.
That is the usual way to combine a picture with a description, and it
needs nothing transparent in the artwork itself.

If you are using 256-wide art, lay your text windows out the classic
way, inside the paper area - the picture occupies the middle of the
screen and leaves the border free.

Setting `COMPRESS=1` in `CONFIG.BAT` ZX0-compresses each converted
picture, which makes for a much smaller SD card image. The interpreter
decompresses on load, so nothing else changes.

## NextDither

Getting a photograph or a painting down to 255 colours that look right
on this hardware is the hard part of location art, and a general-purpose
paint program does it blind - you cannot see the Next's own colours
while you choose them.

**NextDither** is a free converter built for this target. Download it
from <https://absent42.itch.io/nextdither>.

It does the two things this page asks of you, and does them together:
it quantizes to the Next's palette with real dithering and a live
preview of the result, and it reserves palette slot 255 with the
transparency colour so your art comes out ready to use.

### One image

Open the source, pick the **NextDAAD Layer 2** preset, and export an
**indexed PNG** into `IMAGES\` with a numbered name. The build converts
it from there like any other PNG.

That preset frames to 320x256 and letterboxes rather than crops, so
nothing is cut off, and it anchors the picture to the top - padding
collects at the bottom of the screen, which is where a text window
usually sits and where the transparent fill lets your text show through.
Dithering is Floyd-Steinberg with serpentine scanning, which is the
setting that suits most photographic sources.

Choose 256 wide instead if you want [the classic bordered
screen](#the-classic-bordered-screen).

### A folder at a time

NextDither converts a whole folder against a saved preset, so a set of
location pictures comes out consistent rather than tuned one by one.
Point it at your source folder, set the output to `IMAGES\`, and name
the outputs from the source filename so `cellar.png` keeps its identity
through the batch.

Remember the kit needs a **number** in each filename - `001.png`,
`002.png` and so on - so either name your sources that way before the
batch or use the naming pattern to add the number on the way out. A file
without one is refused by the build.

### Transparency

NextDither writes the reserved colour into slot 255 for you, so a hole
you paint in the source is a hole on screen. The rule is the same one
described under [Transparency](#transparency) below - this is the tool
doing it rather than you arranging a palette by hand.

If you do not want any transparency, keep that colour out of the source
art and slot 255 stays unused.

### Other output

NextDither also writes `.NX2` and `.NXI` files directly, along with
ZX0-compressed variants and standalone palettes, and the kit takes those
too - see [Already-converted artwork](#already-converted-artwork).

Either route works. The indexed PNG is the one to reach for by default,
because the build audits the palette of everything it converts and tells
you what it found. A ready-made file is staged untouched, so it only
gets that check if it is uncompressed, and a compressed one cannot be
checked at all.

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

**Where the hole goes.** Text is an 80x32 grid of characters, and a
320-wide picture covers exactly the same area of screen, so one
character cell is **4 picture pixels wide and 8 tall**. To place a hole
for a window opened with `WINAT row column` and `WINSIZE height width`:

```
left   = column x 4        width in pixels  = width  x 4
top    = row    x 8        height in pixels = height x 8
```

So `WINAT 20 4` with `WINSIZE 10 72` wants a hole 288 x 80 pixels with
its top-left corner at pixel (16, 160) of a 320x256 PNG.

256-wide art uses the same cell sizes but sits inset by 32 pixels on
every side, so take 8 off the column and 4 off the row before
converting. That is the arithmetic behind the classic paper area
described above: columns 8 to 71 is 64 cells, 64 x 4 = 256 pixels
across, and rows 4 to 27 is 24 cells, 24 x 8 = 192 pixels down.

**The colour has to be in slot 255.** Only that slot is transparent. The
same magenta anywhere else in your palette comes out opaque, with
nothing on screen to tell you why, so if your hole renders as solid
magenta that is the first thing to check. Most editors let you set a
specific palette slot: in Aseprite you can edit the entry directly, and
in an indexed export from other tools you may need to reorder the colour
table so your transparent colour is last.

**The build reports how many transparent pixels a converted picture has,
but only with `COMPRESS=0`.** A compressed picture has no readable
palette, so a `COMPRESS=1` build reports nothing at all - neither that
count nor the palette-collision warning described in
[Picture format](reference/picture-format.md#9-verifying-your-output). If
you ship compressed art, run one build with `COMPRESS=0` and read them
from that.

The count is the quickest way to confirm the hole is the size you
intended, and to catch one you did not ask for. You can also run the
audit script directly against a converted file, as
[Picture format](reference/picture-format.md#9-verifying-your-output)
describes.

**A picture with no slot-255 pixels is fully opaque**, which is the
normal case - and the case you get by quantizing to 255 colours, indices
0-254, as above. A 256-colour export instead leaves slot 255 in play,
and a handful of pixels landing there become a handful of holes in the
shipped picture.

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

Picture files converted elsewhere are staged untouched - the build does
not try to reconvert them.

**Location pictures go in `IMAGES\`**, named by number exactly as the
PNGs are: `001.NX2` for 320-wide art, `001.NXI` for 256-wide, or a
compressed `001.NX2.ZX0`, `001.N2Z`, `001.NXI.ZX0` or `001.NXZ`. If both
a `001.png` and a ready-made `001.NX2` are there, the PNG conversion
wins. If you have several forms of the same number, the one staged is
the one the interpreter would load first - compressed before
uncompressed.

A `.NX2` or `.NXI` in `IMAGES\` whose name is not a picture number stops
the build rather than being ignored, so a file that could never be
loaded does not pass unnoticed.

**The title screen goes in the kit folder itself**, not in `IMAGES\` -
a ready-made `DAAD.NX2` or `DAAD.NXI`, or a compressed variant. An
`IMAGES\DAAD.png` wins if you have both.

Staged-as-is means the kit never saw your source art, so the palette
audit is the only check these files get, and it can only read the
uncompressed ones. A compressed file is staged unexamined.

[Picture format](reference/picture-format.md) documents the file layout
itself - what the palette bytes mean, what the loader refuses, and which
ZX0 variant to compress with - for anyone writing a converter or paint
tool export.
