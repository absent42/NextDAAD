# Ticker - NextDAAD XBN worked example

## What it shows

A tiny XBN extern that fetches a DAAD user message with SVC_GETMSG and
ticks it, one character per frame, along the bottom row of the 80x32
tilemap.

It demonstrates the three things every XBN author needs to know:

- fetching a message with SVC_GETMSG from a foreground EXTERN call
- copying the result out of the shared staging buffer before it is
  reused (the staging buffer is only valid until the next service call,
  or across a save/load - anything that must survive longer, like the
  per-frame #int hook here, needs its own copy)
- driving per-frame work from the XBN's #int hook, and disarming it
  cleanly both on completion and on request

## How to build

A prebuilt `GAME.XBN` ships in this directory - copy it next to your
own `GAME.DDB` on the SD card (or the folder your interpreter boots
from) and it just works, no toolchain needed.

To rebuild after editing the source (requires sjasmplus on PATH,
https://github.com/z00m128/sjasmplus):

    .\build.ps1

This assembles `ticker.asm` and rewrites `GAME.XBN` here.

## How to wire it into your DSF

The extern exposes two functions:

    EXTERN n 30   ; fetch user message n and arm the ticker
    EXTERN 0 31   ; disarm the ticker

`n` is the message number as it appears in your DSF's `/MTX` block.
A typical process entry:

    EXTERN 0 30    ; start ticking message 0
    PAUSE 100      ; let it run
    EXTERN 0 31    ; stop (optional - a fully ticked message disarms
                    ; itself; this just stops it early if needed)

Only one message can be armed at a time - a second `EXTERN n 30` while
one is already ticking replaces it from the start.
