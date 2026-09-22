# Ticker - NextDAAD XBN worked example

## What it does

A database message, typed or scrolled across a field you place, size
and colour: row, column, width, ink, paper, typewriter or marquee mode,
and speed are all set with their own `EXTERN` function code before you
arm it. It works in both text widths: the field is resolved against the
live width every frame, so a `GFX n 18` switch mid-message carries on in
the new layout.

It is also the kit's worked example for XBN authors: fetching a
database message with `SVC_GETMSG` from a foreground `EXTERN` call,
copying the result out of the shared staging buffer before it is reused
(the buffer is only valid until the next service call, or across a
save/load - anything that must survive longer, like the per-frame `#int`
hook here, needs its own copy), driving per-frame work from the hook,
respecting the runtime text width, and checking `SVC_BUSY` before
writing the tilemap from the hook while a video clip owns it. The source
comments walk through every decision.

## How to build

A prebuilt `GAME.XBN` ships in this directory - copy it next to your
own `GAME.DDB` on the SD card (or the folder your interpreter boots
from) and it just works, no toolchain needed.

To rebuild after editing the source (build.ps1 finds sjasmplus via its
-SjasmPlus parameter, then the kit's tools\sjasmplus\, then PATH;
https://github.com/z00m128/sjasmplus):

    .\build.ps1

This assembles `ticker.asm` and rewrites `GAME.XBN` here.

## Functions

| Call | Effect | Default | Fails (CF set) |
|---|---|---|---|
| `EXTERN n 30` | latch the settings, clear the field, arm on message n | - | message n does not exist |
| `EXTERN p 31` | stop; p = 1 also clears the field | - | never |
| `EXTERN r 32` | row 0-31 | 27 | r > 31 |
| `EXTERN c 33` | start column 0-79 | 0 | c > 79 |
| `EXTERN w 34` | field width 1-80; 0 = to the end of the row | 0 | w > 80 |
| `EXTERN i 35` | ink 0-255 | 7 | never |
| `EXTERN p 36` | paper 0-255 | 0 | never |
| `EXTERN m 37` | mode: 0 typewriter, 1 marquee once, 2 marquee loop | 0 | m > 2 |
| `EXTERN f 38` | speed: frames per step 1-255 | 1 | f = 0 |

Rules:

- A setter (32-38) only stores its value. Nothing on screen changes and
  nothing about a message already running changes. Settings take effect
  at the next `EXTERN n 30`.
- A rejected value fails the entry that called it (carry set) and
  leaves the stored setting alone.
- `EXTERN 0 31` stops the ticker and leaves the text on screen.
  `EXTERN 1 31` stops it and clears the field.
- fn 30 clears only the field it is arming - it never touches the field
  a previous arm used. To MOVE the ticker: `EXTERN 1 31` (stop and
  clear the old field), the setters for the new position, then
  `EXTERN n 30`.
- Indirection works on the first parameter as on every condact, so
  `EXTERN @100 32` sets the row from flag 100.

A typical process entry:

    EXTERN 20 32    ; row 20
    EXTERN 10 33    ; from column 10
    EXTERN 60 34    ; 60 cells wide
    EXTERN 6 35     ; yellow ink
    EXTERN 1 36     ; blue paper
    EXTERN 2 37     ; marquee, looping
    EXTERN 4 38     ; one cell every four frames
    EXTERN 5 30     ; run message 5 there
    ...
    EXTERN 1 31     ; stop and clear the field

`n` is the message number as it appears in your DSF's `/MTX` block.

v2 behaviour: if message `n` does not exist, fn 30 fails the EXTERN
entry (CF set) instead of silently leaving the ticker disarmed. Games
that call fn 30 with a number that might not exist should account for
the entry failing, the same as any other DAAD condition.

## The field

Rows 0-31 are all accepted, but only rows 4-27 are visible on every
display: rows 0-3 and 28-31 sit in the border area, which HDMI scalers
and monitor overscan often crop. A ticker parked there can be invisible
on hardware while an emulator window shows it fine - verify a border
row on your own target display before shipping it.

Width 0 means "to the end of the row". Whatever width you ask for is
clamped to the live text width, so a field that would run off the row
is narrowed to fit. If the field's start column lies beyond the live
width - an 80-column position, then `GFX 1 18` down to 40 columns - the
ticker freezes whole: nothing advances, not even the speed countdown,
until the width returns and the field is on screen again. It does not
restart at column 0; it resumes exactly where it stopped.

## Modes and speed

- **Typewriter** (mode 0): one character per step, wrapping inside the
  field. When the message is fully typed the ticker disarms itself and
  the text stays on screen.
- **Marquee once** (mode 1): the field scrolls the message through and
  off, one cell per step, then disarms with the field blank.
- **Marquee loop** (mode 2): as marquee once, but after the message has
  scrolled off there is a 4-cell gap before it enters again. Runs until
  `EXTERN p 31` or a re-arm.

Speed is frames per step, 1-255. 1 is right for typing; 3-6 reads well
for a marquee. Speed 1 in marquee mode moves the text 50 cells a
second.

## Colour

Ink and paper take the same 0-255 values `INK` and `PAPER` do,
including 227 (transparent paper). Every clear - arming and
`EXTERN 1 31` - paints the field in the ticker's own colours, so a
ticker with a coloured paper shows its field as a solid bar from the
moment it is armed. To make the field disappear when the ticker stops,
set the ticker's paper to the screen's own paper before the arm that
precedes the stop (or arm fresh with that paper and stop again).

On an interpreter whose XBN API version is below 3, the ticker falls
back to white on black silently - fns 35 and 36 still accept their
values, but no colour is resolved. A shipped game should not fail on
the interpreter a player happens to have; this is what the fallback is
for.

## Interactions

- The ticker writes straight into the tilemap. If its row lies inside a
  text window, that window's `CLS`, printing and scrolling will
  overwrite or scroll the ticker's cells - keep the row outside every
  window the game uses (`WINAT`/`WINSIZE`), and below any picture.
- A `GFX n 18` width switch blanks the whole screen, ticker included;
  the ticker carries on writing into the new layout.
- Only one message at a time: a second `EXTERN n 30` replaces the first
  from the start, clearing the field it is arming. See the field rules
  above for moving the ticker.
- A video clip pauses the ticker for its duration and it resumes
  afterwards.

## Behaviour change from the demo version

Arming (`EXTERN n 30`) now clears the field first, in the ticker's own
colours, before typing starts. A game that only ever called
`EXTERN n 30` and `EXTERN 0 31` and never used the new position or
colour functions is otherwise unaffected.
