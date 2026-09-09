# Loader intro

A slideshow with music that plays before your game starts, in its own
program. It is an alternative to the [title screen](graphics.md#title-screens),
not a replacement: a game can ship either, both or neither.

## What you get

- Full-screen 320x256 or bordered 256x192 pictures, the same art rules as
  location pictures, with a hold time and an entry transition per slide:
  cut, fade through any colour, wipes in four directions, dissolve, blinds.
- Music from one of three sources: an Arkos Tracker song (AKY, with a 16K
  slot instead of the game's 10K, or the streamed AYS form loaded into
  memory), a stereo sampled stream converted by ffmpeg from any audio
  file, or a NextDAW song through NextDAW's own runtime player.
- Captions in the game's font or a 16-colour font of your own, with
  typewriter reveal and timing, and a scrolling credits page.
- Skip by any key, fire or mouse button, press-any-key slides, an
  attract loop, and timing that stays right on a 60 Hz display.

## Quick start

Create `INTRO.TXT` in the kit folder:

```
MUSIC AKY AUDIO\STARTER.aks
SKIP ANY 1.0
SLIDE DAAD.NX2 IN FADE 1.0 HOLD 4.0
  TEXT 30 CENTRE "A NextDAAD adventure" INK 255
SLIDE DAAD.NX2 IN CUT HOLD KEY
  TEXT 30 CENTRE "Press any key" INK 254 TYPE
END FADE 1.0
```

Run `BUILD.BAT`. `RELEASE\` now holds `<GAME>.NEX` beside `nextdaad.nex`:
**launch `<GAME>.NEX`**. It plays the show and starts the game. This
example reuses the starter's own title picture (`DAAD.NX2`) and its boot
music (`AUDIO\STARTER.aks`), which is why it works unmodified.
`INTRO.TXT.sample` in the kit folder is this example; rename it to try
it, then point `SLIDE` at your own 320x256 or 256x192 art - the numbered
pictures in `IMAGES\` are a different shape and cannot be used as
slides. Remove `INTRO.TXT` and the next build removes the launcher
again.

## Writing the script

One statement per line. Keywords in any case; `;` starts a comment. Times
are seconds with one decimal place. Colours are the same 0 to 255 numbers
as [INK and PAPER](colours.md). File names are relative to the kit folder,
so `IMAGES\` art and `AUDIO\` songs can be reused; an `INTRO\` folder is a
good home for anything that belongs only to the show.

### Before the first slide

| Statement | Meaning |
|---|---|
| `MUSIC AKY file.aks` | Arkos song, three PSGs, up to 16K after conversion. Needs Arkos Tracker 3. |
| `MUSIC STREAM file.aks` | Arkos song in the streamed form, one to three PSGs, up to 384K, loaded into memory. Needs Arkos Tracker 3. |
| `MUSIC PCM file` | Any audio file ffmpeg reads (wav, mp3, ogg, flac), converted to a stereo stream. Needs ffmpeg. About 31K per second on the card. |
| `MUSIC NDR file.ndr` | A NextDAW export, up to 64K. Needs your own NextDAW install, see below. |
| `FONT GAME` | Captions in the game's font (the default). |
| `FONT sheet.png` | Captions in a 16-colour font, see [Colour fonts](#colour-fonts). |
| `PALETTE n c0 ... c15` | Colour block `n` (1 to 15) for a colour font: sixteen colours. |
| `COLS 40` or `COLS 80` | The caption grid. Defaults to the kit's `COLS` setting, so it matches the game. |
| `BORDER c` | Border colour, seen around 256-wide pictures and wherever no picture covers the screen. |
| `SKIP ANY 1.0` | Any key, fire or mouse button ends the show; presses in the first second are ignored. This is the default. |
| `SKIP SLIDE` | A press advances to the next slide instead. |
| `SKIP NONE` | Presses do nothing except on a `HOLD KEY` slide. |
| `LOOP` | The show repeats until a key. Needs `SKIP ANY`. |

At most one `MUSIC` statement is allowed; music loops for as long as the
show runs. Leave `MUSIC` out for a silent show.

### Slides

```
SLIDE picture IN transition [time] [colour] HOLD seconds
SLIDE picture IN transition [time] HOLD KEY
```

`picture` is a PNG of exactly 320x256 or 256x192 with the
[location art rules](graphics.md#what-the-art-must-be), or an already
converted NX2 or NXI. `IN` says how the slide arrives:

| Transition | What happens |
|---|---|
| `CUT` | Instant. |
| `FADE t [c]` | Fade the previous picture to colour `c` (black unless given; 255 is white) and the new one up from it, over `t` seconds. The border fades too. |
| `WIPE LEFT|RIGHT|UP|DOWN t` | The new picture reveals from one edge; the name is the direction the edge travels. |
| `DISSOLVE t` | Random-order 4x4 blocks over the whole picture. |
| `BLINDS t` | Eight bands, each revealing top to bottom. |

`HOLD` is how long the slide stays once it is fully in; `HOLD KEY` waits
for a press. A slide carrying a `SCROLL` has no `HOLD`.

**Palettes and copy transitions.** A wipe, dissolve or blinds shows two
pictures at once, and Layer 2 has one palette: the incoming picture's
palette is applied as the transition starts, so the outgoing picture is
recoloured while it leaves. The build warns when two such pictures differ
by more than a few palette entries. For a sequence you want to wipe
between, give the pictures one shared palette. A fade has no such
constraint.

**Width changes.** Between a 320-wide and a 256-wide slide only `CUT` and
`FADE` are allowed, since the other transitions copy between two surfaces
of the same shape. The first slide arrives from nothing, so it too takes
`CUT` or `FADE`.

### Captions

```
TEXT row col "text" [AT t] [TYPE] [INK c] [PAPER c] [BLOCK n]
TEXT row CENTRE "text" ...
```

Rows are 0 to 31, columns 0 to 79 (or 39 in a 40-column show). `AT`
delays the caption by `t` seconds after the slide is fully in; `TYPE`
reveals it a character at a time, one every two frames - 25 a second at
50 Hz, 30 at 60 Hz. With the game's font, `INK` and `PAPER` set the
colours (paper is transparent when left out). With a colour font,
`BLOCK` selects one of the sixteen colour blocks. Write a quote inside a
string as two quotes. Captions vanish when the slide leaves. Around a
256-wide picture the rows above and below it are in the border, which is
where a caption under such a picture goes.

### A credits page

```
SLIDE picture IN CUT
  SCROLL SPEED 2 INK 252
  LINE "WRITTEN BY"
  LINE "Someone"
  LINE ""
  LINE "MUSIC"
  LINE "Someone else"
```

The lines rise from the bottom, centred, at `SPEED` pixels per frame (1
to 4); an empty `LINE` is a spacer. The slide ends when the last line has
left the top. `INK`, `PAPER` or `BLOCK` apply to every line. A slide with
`SCROLL` takes no `TEXT` and no `HOLD`, and allows at most 224 `LINE`
statements.

### The end

`END FADE t [c]` fades the last picture to the colour and the music with
it. `END CUT` goes straight to the game. `END` is the last statement.

## Colour fonts

A font sheet is a 128 by 128 PNG: sixteen columns by sixteen rows of 8x8
cells, cell `n` holding character `n`, so it reads like an ASCII table.
At most sixteen colours, saved with a sixteen-entry palette, one of them
magenta (#FF00FF) for transparent. Cell 32, the space, must be entirely
magenta - it is what clears a text cell. The sheet's own colours are
block 0; `PALETTE` lines define blocks 1 to 15 with the same shapes in
other colours, and `BLOCK n` on a caption or a scroll picks one. Index 0
of every block is transparent.

## Music

**AKY and STREAM** take the same `.aks` source as the game's own music
([Audio](audio.md#music)). The intro's AKY slot is 16K, larger than the
game's 10K; a song still too big goes through `STREAM`, which is limited
only by memory (384K). Compose for three PSGs for the AKY form.

**PCM** converts through ffmpeg to unsigned 8-bit stereo at 15625 Hz, the
same format cutscene audio uses. Any source ffmpeg reads works; a mono
source plays centred. The file on the card is about 31K per second, so a
three-minute track is about 5.6 MB.

**NDR** plays a NextDAW export with NextDAW's runtime player. The kit
copies that player from your own NextDAW install into `RELEASE\INTRO\`
at build time, because NextDAW's licence lets you ship it inside your
game but not redistribute it, and the kit never contains it. Set
`NEXTDAWDIR` in `CONFIG.BAT` to the folder holding `RuntimePlayer\`, or
put your copy under `tools\NextDAW\`. Only the E000 build of the runtime
player is accepted - `RuntimePlayer\NextDAW_RuntimePlayer_E000.bin` - and
the exported song is capped at 64K. The licence asks for a credit line
where your game credits its authors:

    Music created using Gari Biasillo's NextDAW

NextDAW has no volume control, so at `END FADE` the notes release
naturally while the picture fades.

## Timing and skipping

Holds, transitions and caption delays keep their length on a 60 Hz
display. With `SKIP ANY`, a press ends the show through the END fade (at
most half a second) and hands over; `HOLD KEY` slides always advance on a
press whatever the skip mode. The key that ended the show is waited out
before the game starts, so it never reaches the game's first prompt. If a
hold is shorter than the next picture takes to load from the card (about
a second for a 320-wide picture, longer while music streams), the hold
simply lasts until the picture is ready.

## What is on the card

`BUILD.BAT` writes `RELEASE\<GAME>.NEX` and a `RELEASE\INTRO\` folder:
`INTRO.DAT` (the compiled script), the pictures as `001.NXC`, `002.NXI`
and so on (`NXC` is a 320-wide picture stored in the hardware's own order
and is not interchangeable with a location picture), `FONT.TIL` for a
colour font, and one of `MUSIC.AKY`, `MUSIC.AYS`, `MUSIC.PCM` or
`MUSIC.NDR` with `NDAW.BIN`. Copy `RELEASE\` to the card as usual and
launch `<GAME>.NEX`. Launching `nextdaad.nex` directly still works and
skips the intro. A game shipping an intro boots without the version
stamp, the same as one shipping a title screen; a game shipping both an
intro and a title shows the intro, then the title.

## When something is missing

The launcher never stops a game from starting on a broken or missing
show: a broken or missing `INTRO.DAT` goes straight to the game, and a
slide whose picture fails to load is skipped (if every slide fails, the
show ends there too, so a `LOOP` cannot spin forever on missing art). A
missing or unusable font falls back to the built-in one, and a music
file that will not open plays silence. Only a missing, unreadable or
refused `nextdaad.nex` is fatal, with the message `E9 nextdaad.nex` on a
magenta border, since there is then no game to start. If a show
misbehaves, check the build output first: every compile error names its
line in `INTRO.TXT`.
