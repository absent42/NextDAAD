# Layer 2 fade extern

Fades the Layer 2 picture to any RRRGGGBB colour and back, while the
text window stays live - fade the scene to black, let the narration
land, fade back up. A classic storytelling device; this extern adds it to any NextDAAD game.

## Use from DSF

    LET 241 0          ; frames per fade step: 0 = default (about 1s)
    EXTERN 0 40        ; fade out to black (any RRRGGGBB byte works:
                       ; 255 = white, 224 = red, 3 = deep blue ...)
    PAUSE 100          ; or poll flag 240 - it reads 1 when the fade
                       ; completes
    ; ... narration ...
    EXTERN 0 41        ; fade back in to the original picture

Fade-out only acts when the picture is fully in; fade-in only when
fully out. Calls at any other moment are ignored - wait on flag 240
between fades. After a completed fade-in the snapshot is forgotten, so
the next fade-out captures whatever picture is on screen by then.

## Build

    ./build.ps1        (sjasmplus on PATH, or set SJASMPLUS)

Copy the resulting GAME.XBN beside your GAME.DDB.

## Rules

- Do not fade while a PICTURE or DISPLAY is drawing, or while a video
  clip is playing: the palette hardware is an indexed register
  interface shared with the interpreter's own graphics machinery.
  Trigger fades from quiet moments and wait for flag 240.
- One XBN per game: to combine this with the ticker example, merge the
  two sources into one binary - the fn codes (40/41 here, 30/31 there)
  and flags do not collide, and each example's ext_main dispatch chain
  ignores the other's codes already.
- The fade manipulates the Layer 2 first palette, the interpreter's
  standing convention. It snapshots and restores 8-bit RRRGGGBB
  values; a picture using 9-bit palette blue depth is restored to
  8-bit precision (the blue LSB is approximated) - imperceptible in
  practice, noted for completeness.
- Transparency is respected: entries holding the Layer 2 transparency
  colour (the interpreter's punched-hole convention, index 255) are
  PINNED - holes stay transparent through the whole fade rather than
  sealing over. Interpolated values that would momentarily equal the
  transparency colour are nudged one blue step, so opaque regions
  never flicker see-through mid-fade. Consequence: you cannot fade TO
  the transparency colour itself - a target of that value fades to
  its nearest neighbour instead.
