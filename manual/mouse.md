# Mouse

The `MOUSE` condact drives a hardware sprite pointer: showing and hiding
it, reading its position and buttons, and installing your own pointer
artwork in place of the default arrow.

A custom pointer is a `POINTER.SPR` file dropped into the kit folder,
staged to the release untouched. Up to nine further numbered variants
can sit beside it and be switched from your source while the game runs.
This is optional - with no `POINTER.SPR` the default arrow plays.

## MOUSE sub-commands

[DAAD Ready's manual](https://www.ngpaws.com/daadready/doc_en.html)
lists, in its Appendix D, symbolic names for the sub-command
argument of `MOUSE` (`SHOWMS`, `HIDEMS`, and so on). The bundled DRF
compiler predefines every one of them, and a DSF written with the
symbolic form compiles byte-identical to the same DSF written with
the raw number - use whichever reads better.

All eight documented sub-commands (0-7) are implemented. A sub-command
number above 7 no-ops silently (a DEBUG build shows a marker), the same
idiom `SFX` uses for a sub-command it does not recognise.

| n | Symbol | Behaviour on this target |
|---|--------|---------------------------|
| 0 | `RESETMS` | Re-centre the pointer at (160,128), zero the buttons, clear the hotspot offset, and re-latch the movement baseline. |
| 1 | `SHOWMS` | Show the hardware sprite pointer. |
| 2 | `HIDEMS` | Hide the hardware sprite pointer. |
| 3 | `GETMS` | Read mouse state into four flags starting at the first argument: `flags[n]` = buttons (idle 0, left 1, right 2, middle 4, chords additive - jdaad parity, not the raw Kempston byte), `flags[n+1]` = column 0-79 (X/8), `flags[n+2]` = row 0-31 (Y/8), `flags[n+3]` = column 0-53 (X/6). |
| 4 | `GETFINEMS` | Fine position into **three** flags: `flags[n]` = buttons (same convention as 3), `flags[n+1]` = X/2 (0-159), `flags[n+2]` = Y undivided (0-255). This is the DRC manual's VGA case, which is what a 320x256 pointer plane is; `flags[n+3]` is NOT written. |
| 5 | `POINTERMS` | Install pointer shape `n` (the first parameter) into hardware sprite slot 0 and re-arm it. `n` 0 always reaches a known shape - the built-in arrow, then `POINTER.SPR` over it if one exists; `n` 1-9 select `POINTER1.SPR` to `POINTER9.SPR`, and a missing or wrong-size file for that number is a silent no-op - the previously-installed shape stays. Classic `.PTR` pointer files remain unsupported: DOS DAAD loads their bytes as indices into a 256-colour palette it reloads per picture, so the same file renders in different colours depending on the current location graphic, with no fixed table here to translate against. Every call re-uploads and re-arms regardless, so the documented `POINTERMS` then `SHOWMS` idiom always leaves slot 0 holding your pointer, whatever else used the slot meanwhile. See [Custom mouse pointer](#custom-mouse-pointer) below. |
| 6 | `DELTAXMS` | Set the pointer's hotspot X offset within its bitmap - **not** a movement delta, despite the symbol name. The reported coordinates do not change; the bitmap shifts so the hotspot pixel lands on the reported position. Floors at the plane origin rather than wrapping. |
| 7 | `DELTAYMS` | As 6, for the hotspot Y offset. |

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
[MOUSE sub-commands](#mouse-sub-commands) above.

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
base font (see [Fonts](fonts.md#numbered-fonts-and-switching-at-runtime)):
it re-probes for `POINTER.SPR` without first restoring the built-in
arrow. If neither the new part nor the root ships one, whatever shape
was active stays active rather than reverting - only `MOUSE 0 5` is
guaranteed to reach a known shape. A game that wants a numbered shape
after a part switch re-selects it with `MOUSE n 5`.

`MOUSE n 5` (`POINTERMS`) is the shape switch described above: it
re-uploads the chosen pattern into hardware sprite slot 0 and re-arms
it, every time, even when the shape requested is already the one
installed - so the documented `POINTERMS` then `SHOWMS` sequence always
leaves slot 0 holding your pointer, whatever else used the slot in
between.
