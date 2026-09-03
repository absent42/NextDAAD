# Animated sprites

A sprite set is a small picture that cycles frames in place: a guttering
torch, running water, a blinking eye, a machine with a moving part. Sets
are drawn by the Next's own sprite hardware, so they sit **above the
location picture and above the text**, and they keep animating while the
game prints, scrolls and waits for input.

Sets do not move. A set is started at a position and cycles there until
something stops it. There is no move, scale, mirror or rotate.

Sprites are optional and cost a game that never uses them nothing: no
reserved flags, no reserved objects, no change to any existing condact.

## The three sub-commands

| Condact | What it does |
|---|---|
| `GFX n 19` | Start sprite set `n` at the position baked into `NNN.ANI` by the kit. |
| `GFX f 20` | The same, but the set number comes from flag `f`, the X position from flags `f+1` (low byte) and `f+2` (high byte), and the Y position from flag `f+3`. |
| `GFX n 21` | Stop set `n` and free the space it held. `n` 255 stops every running set. |

**Set numbers are 0 to 254.** 255 is reserved as the stop-all argument.
Set numbers are their own namespace, nothing to do with picture numbers:
set 3 and picture 3 are unrelated files. The file is looked for in
`PARTn\` first and then in the game's root folder, the same probe order
pictures and `POINTER.SPR` use.

**Positions are picture pixels**, the coordinates you already think in:
0 to 319 across by 0 to 255 down in a 320-wide picture mode, 0 to 255 by
0 to 191 in a 256-wide one. The interpreter places the set on the sprite
plane for you, so the 32-pixel sprite border never appears in your source.

**`GFX f 20` reads its four flags once, at the call, and reserves
nothing.** They are ordinary flags you may use for anything else before
and after; writing to them later does not move a running set. `f` above
252 is refused, because the four reads would run off the end of the flag
table, and so is an X high byte above 1.

**Starting a set that is already running restarts it from frame 0.** It
is not reloaded and nothing is reallocated, so a restart cannot fail and
costs nothing. That holds for `GFX f 20` too: the X and Y in the flags
are ignored on a restart, so a set has to be stopped before it can be
started somewhere else. **Stopping a set that is not running does
nothing.**

**Up to eight sets run at once.** A ninth start is ignored until one
of the eight is stopped.

**A set started later draws over sets started earlier**, and the mouse
pointer stays above all of them whether or not your game ever calls
`MOUSE`.

**Playback.** Every frame carries its own delay, 1 to 255 frame
interrupts. A looping set cycles forever; a one-shot plays to its last
frame and holds that frame on screen until something stops it.

**A start that cannot be satisfied is silently ignored** and the game
carries on: a missing file, a file the loader refuses, no free set, no
room left in one of the budgets below. A release build says nothing at
all; a DEBUG build prints a short marker naming the reason. The reasons
are listed in [ANI format](reference/ani-format.md#4-what-the-loader-refuses).

## Drawing a set

Put the artwork in `IMAGES\SPRITES\`, named by set number, with a
sidecar text file of the same name beside it:

```
IMAGES\SPRITES\002.png
IMAGES\SPRITES\002.txt
```

The build packs each one into `RELEASE\NNN.ANI` and prints a line
naming what it made.

**A sheet, `NNN.png`.** A **paletted 8-bit PNG** (colour type 3 - an
indexed image, not truecolour; anything else is rejected). Frames are
laid out **left to right, wrapping to the next row** when the sheet is
wider than one frame. Sheet width and height are multiples of 16.
Exactly `#FF00FF` in the palette is transparent, and every palette entry
of that colour counts.

**Or a ready-made sprite file, `NNN.spr`.** Output from
`gfx2next -sprites -pal-std`: 256-byte cells, bytes already final. These
are **8-bit only** and are taken exactly as they are, including any byte
that is already the transparent value. A `.spr` whose length is not a
multiple of 256 is not one of these files and is rejected; a compressed
`NNN.spr.zx0` is rejected by name; having both `NNN.png` and `NNN.spr`
for one number is a build error.

There is no ready-made 4-bit input. Four-bit sets come from the PNG path,
where the kit does the colour work itself.

**The sidecar, `NNN.txt`**, is `key=value` lines with `;` for comments:

| Key | Meaning | Default |
|---|---|---|
| `w`, `h` | frame size in pixels, multiples of 16, 16 to 128 | required |
| `x`, `y` | baked position in picture pixels | 0, 0 |
| `sheetw` | sheet width in pixels, for unpacking frames | PNG: the image width. `.spr`: `w` |
| `delay` | ticks per frame: one number, or a comma list with one number per frame | 5 |
| `loop` | 1 cycles forever, 0 plays once and holds the last frame | 1 |
| `frames` | how many frames to take from the sheet | as many as the sheet holds |
| `bits` | 8 or 4 | PNG: 4 when the colours partition into blocks of 15 or fewer, otherwise 8. `.spr`: must be 8 or absent |

The build prints one line per set, so you can see what you got without
opening the file:

```
  sprite 002.ANI: 16x16, 2 frame(s), 2 cell(s), 8-bit, blocks 8000, 532 bytes
```

`blocks 8000` is the palette-block mask of an 8-bit set, one bit per
block, and it is what you need for the coexistence rule below. A 4-bit
set prints its block count instead.

## Budgets

Everything below is shared by every set that is running at the same time,
after what the mouse pointer holds. Stopping a set gives its share back
at once.

| Budget | Ceiling |
|---|---|
| Unique cells, all running sets together | **63** 8-bit cells, or **126** 4-bit cells, or a mix (an 8-bit cell costs two of the 126 slots, a 4-bit cell one) |
| Hardware sprites, all running sets together | **127** (a set uses one per cell of its frame, so `w/16 x h/16` of them) |
| Palette blocks | **16** blocks of 16 colours, less the ones the pointer needs |
| Frame table, per set | **1024** bytes, which is `frames x (1 + cells per frame)` |
| Frame size | 16 to 128 pixels each way, in steps of 16 (at most 8 by 8 cells) |
| Frames per set | 1 to 255 |

A cell is one 16x16 tile of a frame. Identical cells are shared: the kit
packs each distinct cell image once, so a 64x64 frame of sixteen cells
whose corners repeat costs fewer than sixteen.

**The frame table is usually the first ceiling a large set meets.** 1024
bytes is 15 frames at 128x128, 60 frames at 64x64, 204 frames at 32x32
and 255 frames (the frame limit itself) at 16x16.

**Not a limit, but worth knowing:** the sprite unit guarantees at least
100 sprites on any one scanline. Eight sets of the widest possible
frames, plus the pointer, is 65 sprites on a line, so no arrangement of
sets can reach that guarantee. There is no per-line rule to design
around.

## 8-bit and 4-bit sets together

Every sprite on screen shares one 256-colour sprite palette, the pointer
included. Think of it as **16 blocks of 16 colours**.

- **An 8-bit set's bytes are palette indices.** Its colours must sit at
  exactly the entries they name, so every block the set's bytes fall in
  has to keep the palette's default contents. The mouse pointer is 8-bit
  too, and needs the blocks its own artwork uses.
- **A 4-bit set claims whole blocks** and writes its own 16 colours into
  each. That is what lets it pack two pixels per byte and use half the
  pattern space.

So the rule is a simple one: **a 4-bit set may not claim a block that an
8-bit set or the pointer is using, and an 8-bit set may not use a block a
4-bit set has claimed.** A start that would collide is ignored, and
nothing on screen changes. Stopping a 4-bit set restores the default
colours in its blocks, so the space becomes usable again immediately.

A game whose sets are all one kind never meets this rule at all. If you
do mix them, the build's `blocks` mask for each 8-bit set tells you which
blocks are spoken for, and a 4-bit set takes the lowest free blocks it
can find.

**Installing a different pointer with `MOUSE n 5` while a 4-bit set is
running does not re-check the rule**, so the new pointer's colours can
land in blocks the set has already claimed. Change pointers before you
start 4-bit sets, not after.

**Transparency is `#FF00FF` magenta**, as it is everywhere else in the
kit. In an 8-bit set magenta becomes the hardware's transparent colour,
and an opaque colour that happens to land on that same value is nudged
one step up the green scale so it draws instead of punching a hole - the
same defence picture palettes get. In a 4-bit set, entry 3 of each block
is the transparent one and the kit puts your magenta there.

## What stops a set

Sets are transient, like a picture. These stop every running set and free
everything they held:

- `PICTURE` and `DISPLAY`, including of the picture already on screen
- `END`
- a completed `LOAD` or `RAMLOAD`
- starting a video with `GFX 13` or `GFX 14`
- a change of part

These do **not** touch a running set: `RESTART`, `CLS`, the window
condacts, `GFX 17` (layer order), `GFX 18` (text width), `MOUSE`,
installing a font, and `SAVE`. A set keeps playing through all your text
output and while the game waits for a key.

`RESTART` is deliberately absent from the first list. In a template game
it is the per-move re-entry into the response loop, so a set that died
there would be unusable in practice.

**Animation state is never saved.** A save file records no sets, and a
restored game starts with none running. Re-issue the starts you want
where you re-issue `PICTURE`, in the location process, and the room comes
back complete.

**A restarted set costs no card read after the first one.** The file
image stays in memory once loaded, so stopping and starting a set as the
player walks in and out of a location touches the SD card only the first
time. A change of part clears that, since set numbers belong to the part.

**Sprites are off for the whole of a video** and come back when it ends,
with no sets running. Start the ones you want again after the video.

## Timing

Frame delays are counted in frame interrupts, so a set plays at the
machine's frame rate: 50 ticks a second in a 50 Hz display mode, 60 in a
60 Hz one, and a set authored to look right at 50 Hz runs about a fifth
faster at 60.

At 60 Hz a frame change on a large multi-cell set can also show a single
torn frame, where part of the set has changed and part has not. It lasts
one frame and does not accumulate. Small sets are unaffected.
