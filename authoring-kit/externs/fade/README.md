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
| `EXTERN 0 42` | re-snapshot: the PICTURE changed while faded out |
| `EXTERN 0 43` | block until the running fade finishes |

Fade-out only acts when the picture is fully in; fade-in only when
fully out. Calls at any other moment are ignored, so wait for one fade
before starting the next. After a completed fade-in the snapshot is
forgotten, so the next fade-out captures whatever picture is on screen
by then.

## Waiting for a fade

The fade runs in the interrupt hook, so your game keeps going while it
steps. There are two ways to wait, and they are for different jobs.

**`EXTERN 0 43` - just wait.** One line, and the right answer for a
plain scene transition. It blocks the condact stream until the fade
finishes, so nothing else runs meanwhile.

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

## Changing the picture while faded out

The snapshot is taken once, when the fade OUT starts. A fade IN walks
back to that snapshot - so if you change the picture in between, fn 41
would restore the old picture's colours onto the new picture's pixels.

`DISPLAY 0` also loads the new picture's palette as it flips, so the
new scene would otherwise appear at once, at full brightness, with no
fade at all. `EXTERN 0 42` handles both: it re-snapshots what `DISPLAY`
just programmed and puts the fade colour straight back on screen.

    LET 241 6
    EXTERN 0 40        ; fade out to black
    EXTERN 0 43        ; wait for it
    PICTURE 5
    DISPLAY 0          ; new bitmap and its palette
    EXTERN 0 42        ; re-snapshot it, hold the black
    EXTERN 0 41        ; fade up to the NEW picture
    EXTERN 0 43        ; wait for it

Keep `DISPLAY 0` and `EXTERN 0 42` in the same process entry. Both are
condacts, so they complete inside one frame and the full-brightness
flip is never displayed.

## Build

A prebuilt GAME.XBN ships in this directory - copy it beside your
GAME.DDB and it just works. To rebuild after editing the source:

    ./build.ps1        (sjasmplus on PATH, or set SJASMPLUS)

## Rules

- Do not fade while a PICTURE or DISPLAY is drawing, or while a video
  clip is playing: the palette hardware is an indexed register
  interface shared with the interpreter's own graphics machinery.
  Trigger fades from quiet moments and wait for the fade to finish.
  The one deliberate exception is the `DISPLAY 0` / `EXTERN 0 42` pair
  above, where the fade is parked at its solid end and nothing is
  stepping.
- One XBN per game: to combine this with the ticker extern, merge the
  two sources into one binary - the fn codes (40 to 43 here, 30/31
  there) and flags do not collide, and each source's ext_main dispatch
  chain ignores the other's codes already.
- The fade manipulates the Layer 2 first palette, the interpreter's
  standing convention. The snapshot captures full 9-bit colour - both
  the `RRRGGGBB` byte and the second byte holding the blue LSB and the
  Layer 2 per-pixel priority bit - and a completed fade-in restores it
  exactly, bit for bit. The interpolated steps in between are computed
  in 8 bits, which is invisible at six frames a step.
- Transparency is respected: entries holding the Layer 2 transparency
  colour (the interpreter's punched-hole convention, index 255) are
  PINNED - holes stay transparent through the whole fade rather than
  sealing over. Interpolated values that would momentarily equal the
  transparency colour are nudged one blue step, so opaque regions
  never flicker see-through mid-fade. Consequence: you cannot fade TO
  the transparency colour itself - a target of that value fades to
  its nearest neighbour instead.
