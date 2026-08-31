# timer

Three independent countdown timers, driven from the XBN frame hook. A timer
counts down in real seconds or in-game minutes and expires into a flag your
process table can test - no EXTERN call is needed to run the countdown, only
to arm the module once.

## EXTERN codes

- `EXTERN 0 63` - arm the module. Until this runs the hook ignores flags
  229-237 entirely, so an unused timer module costs the author nothing.
- `EXTERN 0 64` - stop all three timers. Each remaining count is left alone
  so the author can still inspect it; only the three states clear.
- `EXTERN d 65` - slot d: convert its pair from a DURATION in minutes to an
  absolute deadline, and start it counting in-game minutes.

## Flags

- 229/230, 231/232, 233/234 - one 16-bit pair per slot (low byte first). In
  state 1 this is remaining real seconds; in state 2 it is an absolute
  in-game-minutes deadline. 16 bits because a byte caps a real-seconds timer
  at 255, and "you have five minutes" would not fit.
- 235, 236, 237 - state, one byte per slot. 0 idle, 1 running in real
  seconds, 2 running in in-game minutes, 3 expired.

## Arming a timer

A real-seconds timer is armed by writing two flags, as before:

    LET 229 44     ; remaining, low byte
    LET 230 1      ; high byte: 1*256 + 44 = 300 seconds
    LET 235 1      ; state 1 = running, counting real seconds

An in-game-minute timer is armed by writing the DURATION and then calling the
module, which converts it to a deadline:

    LET 229 90     ; 90 in-game minutes
    LET 230 0
    EXTERN 0 65    ; slot 0: convert to a deadline and start counting

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
jumping the clock forward past that deadline expires it on the next frame, and
jumping backwards gives it more time. That is the sensible reading of both, and
it needs no special handling around a save or a load.

## Notes

The clock's hour, minute and day flags (224, 225, 244) are read-only from this
module's side; it never writes them, and the two modules can be built and
shipped independently. An armed state-2 timer reads them unconditionally,
though, so in a timer-only build those flags are not the author's to reuse. A
real-seconds timer that reaches zero clamps there and expires rather than
wrapping past zero, whatever the size of the step that finished it off.
