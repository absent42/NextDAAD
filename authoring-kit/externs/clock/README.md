# clock

An in-game clock advanced from the XBN frame hook. The authoritative time
lives in flags, not in the module's own memory, so a LOAD needs no re-sync -
the hook simply carries on from whatever the flags now say.

## EXTERN codes

- `EXTERN 0 60` - arm the module and start the clock, on the first call
  only. Arming is bank state and survives RESTART, a part switch and a
  LOAD, so a repeat call while already armed is a no-op - even if the
  clock has since been stopped with `EXTERN 0 61`; restart it with
  `LET 226 1` instead. A rate of 0 at first arm defaults to 50 (one
  in-game minute per real second).
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
- 244 - days elapsed (0-255)

Setting the time is a plain `LET 224 h` / `LET 225 m` - no EXTERN call
needed, and nothing to restore after a LOAD since the flags are the only
copy of the time that exists.

Flag 244 counts days elapsed. It starts at 0, and rolls forward by one every
time the hour passes 23, whether the minute came from the clock running or from
`EXTERN p 62`. Set it with a plain `LET 244 3` like any other flag, and test it
the same way:

    > _  _    EQ  244 3
              ; the siege reaches its third day

It wraps from 255 back to 0. That wrap is a discontinuity in in-game time
rather than a step, so do not leave an in-game-minute timer armed across
it. It is 255 in-game days away - at the default rate (one in-game minute
per real second) that is about 4 days 6 hours of continuous play; only at
rate 3000 (true 1:1) is it 255 real days.

The rate is 16-bit. 50 gives one in-game minute per real second; 3000
gives true 1:1 real time (50 frames/second x 60 seconds). Writing a rate of
0 while the clock is running silently halts it - the zero-rate default only
applies at arm time.

The hook measures elapsed frames as a delta from the interpreter's own frame
counter each pass, not by counting hook invocations: whatever the game was
doing between two passes, the true number of frames elapsed is what
accumulates towards the rate, so frames the hook itself was not invoked for
(a video clip, a long blit) are still counted once it resumes rather than
lost.

Arming with `EXTERN 0 60` is remembered for the whole session - it survives
`RESTART`, a part switch and a `LOAD` - so after `EXTERN 0 61` you can restart
the clock with a plain `LET 226 1`. A fresh boot is a different matter: the
module starts disarmed every time the game is loaded, so `EXTERN 0 60`
belongs in your start process, the way classic DAAD games initialised
externs from PRO 6. The frame counter is re-primed on every hook pass even
while stopped, so that restart never bursts the minutes that passed while
the clock was frozen.

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
per turn, the way any other status line works. The toolkit module's fn 82
prints the pair as HH:MM - `EXTERN 224 82` - and ships in this same
collection and in the same `all/GAME.XBN`; without the toolkit module,
print flags 224 and 225 as plain numbers.

## Advancing time and armed timers

`EXTERN p 62` moves the clock forward in one go - 1 to 255 minutes per call,
with hour and day carry - which is what you want for sleeping or travelling.
Setting the flags directly with `LET 224 18`, `LET 225 0` or `LET 244 3`
moves in-game time just the same, forwards or backwards.

An in-game-minute timer holds an absolute deadline rather than a countdown,
so however you move the clock it simply keeps watching: move past a deadline
and that timer expires on the next frame, move backwards and it gains that
much more time. Both hold for jumps under 32768 in-game minutes (about 22
days 18 hours): a larger backwards jump wraps and reads as already passed,
expiring the timer, while a forward jump that overshoots the deadline by more
than that wraps the other way and reads as still in the future, so the timer
never fires.

Arming one belongs to the separate timer module (`EXTERN d 65`) and is
documented there. It is the only way to arm one: writing a duration into the
flag pair and setting the state by hand leaves a deadline that many minutes
past day 0 00:00, which the clock has almost always passed already, so the
timer expires on the next frame with no diagnostic.
