# clock

An in-game clock advanced from the XBN frame hook. The authoritative time
lives in flags, not in the module's own memory, so a LOAD needs no re-sync -
the hook simply carries on from whatever the flags now say.

## EXTERN codes

- `EXTERN 0 60` - arm the module and start the clock. Arming is bank state
  and survives RESTART, a part switch and a LOAD. A rate of 0 at arm time
  defaults to 50 (one in-game minute per real second).
- `EXTERN 0 61` - stop the clock. The module stays armed; only the running
  flag clears.
- `EXTERN p 62` - advance the clock p in-game minutes in one foreground
  call, with hour carry. Used for sleeping or travelling.

## Flags

- 224 - hours (0-23)
- 225 - minutes (0-59)
- 226 - running (0 stopped, 1 running)
- 227/228 - rate: frames per in-game minute, 16-bit (low byte 227, high
  byte 228)

Setting the time is a plain `LET 224 h` / `LET 225 m` - no EXTERN call
needed, and nothing to restore after a LOAD since the flags are the only
copy of the time that exists.

The rate is 16-bit. 50 gives one in-game minute per real second; 3000
gives true 1:1 real time (50 frames/second x 60 seconds). Writing a rate of
0 while the clock is running silently halts it - the zero-rate default only
applies at arm time.

Arming with `EXTERN 0 60` is remembered for the whole session - it survives
`RESTART`, a part switch and a `LOAD` - so after `EXTERN 0 61` you can restart
the clock with a plain `LET 226 1`. A fresh boot is a different matter: the
module starts disarmed every time the game is loaded, so `EXTERN 0 60`
belongs in your start process, the way classic DAAD games initialised
externs from PRO 6.

## Making an event happen at a given time

An event at 14:37 is an ordinary process entry testing flags 224 and 225 -
the module needs no alarm machinery, and there is nothing to restore after a
LOAD.

    > _  _    EQ  224 14
              EQ  225 37
              ; the guard returns

But a flag changing while the player sits at the prompt is invisible until a
turn runs, so on its own that entry only fires when the player happens to
type. DAAD's input timeout is the other half: flag 48 arms it, in seconds,
and flag 49 bit 7 reports that it fired. With it armed, a turn happens on a
timer and the event fires while the player is still thinking. Without it,
"real time" quietly is not.

## Showing the time

This module never writes the screen. Print the time from your own window,
per turn, the way any other status line works. Until the toolkit module
ships its HH:MM format, print flags 224 and 225 as plain numbers.

## Advancing time and countdown timers

`EXTERN p 62` moves the clock forward in one go, which is what you want for
sleeping or travelling. A countdown timer running in in-game minutes is
charged the whole jump, provided it is under 256 minutes: an advance of 90
minutes costs it 90, and one of 60 costs it 60.

SETTING the time forward with a plain `LET 224 18` is charged the same way,
up to that same 256-minute limit. A jump of 256 minutes or more, or any
backwards move - including one caused by a LOAD restoring an earlier time
than a running timer last saw - is a discontinuity: the timer silently
re-syncs to the new time and is charged nothing that frame. A running
in-game-minute timer therefore survives a LOAD correctly, with nothing for
the author to re-sync.
