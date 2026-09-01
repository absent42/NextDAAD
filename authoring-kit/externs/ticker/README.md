# Ticker - NextDAAD XBN worked example

## What it shows

A tiny XBN extern that fetches a DAAD user message with SVC_GETMSG and
ticks it, one character per frame, along the bottom row of the tilemap.
It works in both text widths: each frame it calls xbn_width for the
live row address and column count, so a `GFX 1 18` switch mid-message
just carries on at the new width.

It demonstrates the things every XBN author needs to know:

- fetching a message with SVC_GETMSG from a foreground EXTERN call
- copying the result out of the shared staging buffer before it is
  reused (the staging buffer is only valid until the next service call,
  or across a save/load - anything that must survive longer, like the
  per-frame #int hook here, needs its own copy)
- driving per-frame work from the XBN's #int hook, and disarming it
  cleanly both on completion and on request
- respecting the runtime text width: the interpreter's width byte is
  not part of the frozen XBN ABI, so the extern calls xbn_width for
  the live row address and column count - the pattern any extern that
  writes the tilemap needs
- checking SVC_BUSY before writing the tilemap from the hook: while a
  video clip is playing, the interpreter borrows the tilemap as the
  clip's audio ring buffer, so the ticker skips emission that frame
  instead of corrupting the clip's sound

## How to build

A prebuilt `GAME.XBN` ships in this directory - copy it next to your
own `GAME.DDB` on the SD card (or the folder your interpreter boots
from) and it just works, no toolchain needed.

To rebuild after editing the source (build.ps1 finds sjasmplus via its
-SjasmPlus parameter, then the kit's tools\sjasmplus\, then PATH;
https://github.com/z00m128/sjasmplus):

    .\build.ps1

This assembles `ticker.asm` and rewrites `GAME.XBN` here.

## How to wire it into your DSF

The extern exposes two functions:

    EXTERN n 30   ; fetch user message n and arm the ticker
                  ; CF clear: armed. CF set: message n does not exist -
                  ; this EXTERN entry fails (v2)
    EXTERN 0 31   ; disarm the ticker (always succeeds, CF clear)

`n` is the message number as it appears in your DSF's `/MTX` block.
A typical process entry:

    EXTERN 0 30    ; start ticking message 0
    PAUSE 100      ; let it run
    EXTERN 0 31    ; stop (optional - a fully ticked message disarms
                    ; itself; this just stops it early if needed)

Only one message can be armed at a time - a second `EXTERN n 30` while
one is already ticking replaces it from the start.

v2 behaviour change: if message `n` does not exist, fn 30 now FAILS the
EXTERN entry (CF set) instead of the v1 behaviour of silently leaving
the ticker disarmed. Games that call fn 30 with a number that might not
exist should account for the entry failing, the same as any other DAAD
condition.
