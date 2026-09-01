# Layer 2 fade extern

Fades the Layer 2 picture to any RRRGGGBB colour and back, while the
text window stays live - fade the scene to black, let the narration
land, fade back up. A classic storytelling device; this extern adds it to any NextDAAD game.

## Use from DSF

    LET 241 0          ; frames per fade step: 0 = default (about 1s)
    EXTERN 0 40        ; fade out to black (any RRRGGGBB byte works:
                       ; 255 = white, 224 = red, 3 = deep blue ...)
    EXTERN 0 43        ; block until the fade finishes
    ; ... narration ...
    EXTERN 0 41        ; fade back in to the original picture
    EXTERN 0 43        ; block until that finishes too

| fn | Does |
|----|------|
| `EXTERN c 40` | fade OUT to RRRGGGBB colour `c` |
| `EXTERN 0 41` | fade IN to the snapshot taken by fn 40 |
| `EXTERN 0 42` | re-snapshot the staged palette (buffer mode only) |
| `EXTERN 0 43` | block until the running fade finishes |

All four are ACTIONS: they always succeed and never abort the entry
they are in. That matters for the buffered sequence below, where a
condact that could FAIL between `GFX 0 4` and `GFX 0 3` would leave
buffer mode open with nothing left to close it.

Fade-out only acts when the picture is fully in; fade-in only when
fully out. Calls at any other moment are ignored, so wait for one fade
before starting the next. After a completed fade-in the snapshot is
forgotten, so the next fade-out captures whatever picture is on screen
by then.

`EXTERN c 40` is also refused if another extern in the same binary
already holds the Layer 2 palette. Nothing fades, and flag 240 is set
to 1 so `EXTERN 0 43` returns at once instead of waiting for a
completion that will never come; `EXTERN 0 41` is then a no-op.

## Waiting for a fade

The fade runs in the interrupt hook, so your game keeps going while it
steps. There are two ways to wait, and they are for different jobs.

**`EXTERN 0 43` - just wait.** One line, and the right answer for a
plain scene transition. It blocks the condact stream until the fade
finishes, so nothing else runs meanwhile. The wait is bounded in real
frames, read from the interpreter's own frame counter, so it can
neither hang nor be hurried along by the interrupts a sampled sound
effect generates while it waits.

**Flag 240 - wait while doing something else.** The hook clears it when
a fade starts and sets it to 1 when the fade completes. Poll it when
the fade is *supposed* to overlap other work, which is the point of
fading with the text window live: `EXTERN 0 43` would stop you printing
during the fade. Polling a flag in DAAD needs a two-entry loop:

    > _  _    PAUSE   1
    > _  _    ZERO    240
              SKIP    -2

`SKIP -2` re-runs the previous entry, so the pair loops until flag 240
goes non-zero; then `ZERO 240` fails, the entry is abandoned, and your
process carries on with the next one.

A plain `PAUSE` long enough to cover the fade also works and is fine
while testing, but it is fragile to ship: a fade is `8 x flag241`
frames, while `PAUSE` durations are scaled by the compiler, so a value
tuned by eye can drift when either changes.

## Sharing the palette

Only one extern in a binary may drive the Layer 2 palette at a time -
two of them writing the same entries would corrupt it - so the
collection keeps a single owner byte and the fade claims it.

The HOLD SPAN is the whole faded-out span: the fade takes the palette
at `EXTERN c 40` and hands it back only when a fade IN completes. A
`RESTART` while faded out does not hand it back, because the palette
banks themselves survive a restart: the owner byte stays claimed until
the next completed fade-in. That is harmless while the fade is the
only palette module in your binary, and it is the reason the fade,
not the restart, decides when the colours are someone else's again.

## Changing the picture while faded out

The snapshot is taken once, when the fade OUT starts. A fade IN walks
back to that snapshot - so if you change the picture in between, fn 41
would restore the old picture's colours onto the new picture's pixels.

`EXTERN 0 42` fixes that: it re-takes the snapshot from the NEW
picture's palette and puts the fade colour straight back on screen, so
`EXTERN 0 41` then fades up to the new picture instead of the old one.

fn 42 reads the palette `DISPLAY 0` staged in the Layer 2 bank the
screen is not showing, and only buffer mode puts it there. So a scene
change through a fade MUST use the sequence below - `GFX 0 4` before
the `DISPLAY 0`, `GFX 0 3` after the reveal. Without buffer mode there
is no staged palette for fn 42 to read.

### Buffered scene change fade

Pair the fade with the interpreter's `GFX` draw-target subs (condact
87, subs 3/4) to stage the new picture off-screen and reveal it only
once its palette is already solid, so the new picture never appears at
full brightness even for a fraction of a frame:

    LET 241 6
    EXTERN 0 40        ; fade out to black
    EXTERN 0 43        ; wait for it
    PICTURE 5          ; CONDITION - aborts here on missing or
                       ; unloadable art, before anything touches
                       ; the draw target
    GFX 0 4            ; open buffer mode - graphics draw to the
                       ; hidden surface only, screen untouched
    DISPLAY 0          ; new bitmap + palette staged, NOT revealed
    EXTERN 0 42        ; re-snapshot the staged palette, hold the
                       ; black, solid it into both palette banks
    GFX 0 2            ; reveal: surface flip + resolution + palette
                       ; land together, atomically
    GFX 0 3            ; close buffer mode - drawing targets the
                       ; screen again
    EXTERN 0 41        ; fade up to the NEW picture
    EXTERN 0 43        ; wait for it

`PICTURE` comes BEFORE `GFX 0 4`, not after. `PICTURE` is a condition -
it fails and aborts the entry on missing or unloadable art (this
interpreter's PICTURE has no darkness handling of its own). Opening
buffer mode first and letting `PICTURE` abort afterwards would strand
buffer mode open, since the aborted entry never reaches the `GFX 0 3`
that would have closed it again.

Buffer mode is transient, but only up to a point: once `GFX 0 4` opens
it, it stays open until `GFX 0 3`, `RESTART`, a same-part
`LOAD`/`RAMLOAD`, or any game (re)start - whichever comes first.
Revealing the picture (`GFX 0 2`) does not close it on its own - that
is why the sequence above always ends with an explicit `GFX 0 3`, even
though the picture is already on screen by then.

## Build

A prebuilt GAME.XBN ships in this directory - copy it beside your
GAME.DDB and it just works. To rebuild after editing the source:

    ./build.ps1        (finds sjasmplus via its -SjasmPlus parameter,
                        then the kit's tools\sjasmplus\, then PATH)

## Rules

- Do not fade while a PICTURE or DISPLAY is drawing, while a video
  clip is playing, or while `GFX 0 2`/`GFX 0 3` (the reveal subs) are
  running: the palette hardware is an indexed register interface
  shared with the interpreter's own graphics machinery. A
  still-stepping fade overlapping a reveal can land the interrupt
  hook's write mid-mirror and corrupt one palette entry. Trigger fades
  from quiet moments and wait for the fade to finish (`EXTERN 0 43` or
  flag 240) before running a reveal. The one deliberate exception is
  the buffered `DISPLAY 0` / `EXTERN 0 42` pair above, where the fade
  is parked at its solid end and nothing is stepping.
- One XBN per game: to combine this with other collection externs, use
  the prebuilt `all/GAME.XBN`, or build a subset with `EXTERNS.BAT`
  from the kit root - see `externs/README.md`. Nothing is merged by
  hand; fn codes and flags are disjoint across the collection.
- The fade manipulates the Layer 2 first palette, the interpreter's
  standing convention. The snapshot captures full 9-bit colour - both
  the `RRRGGGBB` byte and the second byte holding the blue LSB and the
  Layer 2 per-pixel priority bit - and a completed fade-in restores it
  exactly, bit for bit. Every interpolated step is streamed at 9 bits
  too. That is not a refinement: blue is a 3-bit channel like red and
  green, but the packed byte carries only its top two bits and the
  8-bit palette register fills the third in itself, so a fade computed
  on the packed byte alone moves blue in steps twice the size of red's
  and the two channels drift apart mid-fade. Interpolating and writing
  all nine bits keeps every channel on the same eight-level ramp.
- Transparency is respected: entries holding the Layer 2 transparency
  colour (the interpreter's punched-hole convention, index 255) are
  PINNED - holes stay transparent through the whole fade rather than
  sealing over. Interpolated values that would momentarily equal the
  transparency colour are nudged one step up in green, so opaque
  regions never flicker see-through mid-fade. Consequence: you cannot
  fade TO the transparency colour itself - a target of that value
  fades to its nearest neighbour instead.
