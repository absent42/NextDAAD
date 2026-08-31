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

## Flags

- 229/230, 231/232, 233/234 - remaining, one 16-bit pair per slot (low byte
  first). 16 bits because a byte caps a real-seconds timer at 255, and "you
  have five minutes" would not fit.
- 235, 236, 237 - state, one byte per slot. 0 idle, 1 running in real
  seconds, 2 running in in-game minutes, 3 expired.

## Arming a timer

Writing two flags starts one. There is no EXTERN call per timer.

    LET 229 44     ; remaining, low byte
    LET 230 1      ; high byte: 1*256 + 44 = 300 seconds
    LET 235 1      ; state 1 = running, counting real seconds

    > _  _    EQ  235 3      ; state 3 = expired
              LET 235 0      ; clear it so the entry fires once
              ; the bomb goes off

State 2 counts in in-game minutes instead of seconds, so the same three slots
cover "you have ninety seconds" and "you have ninety minutes of game time".
State 2 needs the clock module present and running: with no clock there are no
in-game minutes, and such a timer simply never advances.

A state-2 timer is charged for the whole of a clock jump, so `EXTERN 90 62`
costs it ninety minutes and `EXTERN 60 62` costs it sixty. It cannot tell a
jump from an author SETTING the clock with a plain `LET 224 18`, so that is
charged too - stop in-game-minute timers across a time set, or set the time
before starting them.

## Notes

The clock's hour and minute flags (224, 225) are read-only from this module's
side; it never writes them, and the two modules can be built and shipped
independently. A timer that reaches zero clamps there and expires rather than
wrapping past zero, whatever the size of the step that finished it off.
