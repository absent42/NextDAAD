# timer

Three independent timers, driven from the XBN frame hook, each expiring into
a flag your process table can test. A real-seconds timer counts down once
armed with two flags. An in-game-minute timer needs one more step: an EXTERN
call to convert an authored duration into an absolute deadline, since a DSF
process cannot add a 16-bit duration to a 16-bit clock total itself.

## EXTERN codes

- `EXTERN 0 63` - arm the module. Until this runs the hook ignores flags
  229-237 entirely, so an unused timer module costs the author nothing. Both
  arming forms below need this to have run once, typically from your start
  process - fn 65 does not set it.
- `EXTERN 0 64` - stop all three timers. Each slot's pair is left alone: for
  a real-seconds slot that is still a count the author can inspect, for a
  minute slot it is a deadline that simply stops being watched. Only the
  three states clear.
- `EXTERN d 65` - slot d: convert its pair from a DURATION in minutes to an
  absolute deadline, and start it counting in-game minutes. Maximum duration
  32767 minutes (about 22 days 18 hours) - see Arming below.

## Flags

- 229/230, 231/232, 233/234 - one 16-bit pair per slot (low byte first). In
  state 1 this is remaining real seconds; in state 2 it is an absolute
  in-game-minutes deadline, valid up to 32767 minutes ahead of the clock's
  current total. 16 bits because a byte caps a real-seconds timer at 255,
  and "you have five minutes" would not fit.
- 235, 236, 237 - state, one byte per slot. 0 idle, 1 running in real
  seconds, 2 running in in-game minutes, 3 expired.
- On expiry a real-seconds pair clamps to zero; a minute pair is left holding
  the stale deadline it reached - only the state flag changes.

## Arming a timer

A real-seconds timer is armed by writing two flags, as before - this assumes
`EXTERN 0 63` has already run once:

    LET 229 44     ; remaining, low byte
    LET 230 1      ; high byte: 1*256 + 44 = 300 seconds
    LET 235 1      ; state 1 = running, counting real seconds

An in-game-minute timer is armed by writing the DURATION and then calling the
module, which converts it to a deadline. This also assumes `EXTERN 0 63` has
run, and additionally needs the clock module present and running (`EXTERN 0
60`) - with no clock there are no in-game minutes, and such a timer simply
never advances:

    LET 229 90     ; 90 in-game minutes
    LET 230 0
    EXTERN 0 65    ; slot 0: convert to a deadline and start counting

The duration must be under 32768 minutes. `EXTERN 65` arms a deadline by
adding the duration to the clock's current total mod 65536; the sweep in the
frame hook reads a difference of 32768 or more as already passed, so a larger
duration expires the timer on the very next frame with no diagnostic.

After that call the pair no longer holds a countdown - it holds the in-game
time at which the timer expires. Read state 235 for the answer you want:

    > _  _    EQ  235 3      ; state 3 = expired
              LET 235 0
              ; the bomb goes off

This is why an in-game-minute timer survives a save and reload correctly: the
deadline, the clock and the day counter are all flags, so a LOAD restores them
together and the timer simply keeps counting toward the same moment.

Setting the clock with `LET 224` / `LET 225`, or the day with `LET 244`, moves
in-game time directly. A running minute timer expires at its deadline, so
jumping the clock forward past that deadline expires it on the next frame,
and jumping backwards gives it more time - provided the jump is under 32768
minutes (about 22 days 18 hours); a larger backwards jump wraps around and
reads as already passed instead. That is the sensible reading of both, and it
needs no special handling around a save or a load.

## Notes

The clock's hour, minute and day flags (224, 225, 244) are read-only from this
module's side; it never writes them, and the two modules can be built and
shipped independently. An armed state-2 timer reads them unconditionally,
though, so in a timer-only build those flags are not the author's to reuse. A
real-seconds timer that reaches zero clamps there and expires rather than
wrapping past zero, whatever the size of the step that finished it off.

The day flag (244) wraps from 255 back to 0 rather than growing without
bound, and that wrap is a discontinuity in the clock's total, not a smooth
step - it can make an armed minute timer's deadline comparison wrong for that
frame. Do not leave a minute timer armed across day 255 rolling to day 0; at
the default tick rate that is 255 days of continuous in-game time.
