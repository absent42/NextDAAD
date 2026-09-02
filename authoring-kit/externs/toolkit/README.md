# toolkit

A collection of small pure-logic helpers: decimal printing, 16-bit
arithmetic and time formatting. Unlike `clock` or `timer`, toolkit has no
frame hook - every function runs to completion inside the single
foreground `EXTERN` that calls it. The module implements fifteen
functions: fn 70 and fn 71 for decimal printing, fn 72 to fn 75 for
16-bit arithmetic on flag pairs, fn 76 to fn 81 for object queries and a
random-without-repeat picker, fn 82 and fn 83 for time formatting, and
fn 84 to set a print target window. Four of them - fn 70, 71, 82 and 83
- are also reachable through DAAD's CALL condact, a second entry point
alongside the existing EXTERN dispatch (see CALL slots below).

The parameter is not one thing: fns 70 to 75, 82 and 83 take a flag
NUMBER, and fns 78 to 81 take a value - a location, a noun word id or an
attribute bit. Fn 84 takes a window number.

Two of them arm module state, and it is not flag state: fn 76's picker
pool (see Random without repeat below) and fn 84's print target. The
module has no hook and no `LOAD` logic, so neither a `LOAD` nor a
`RESTART` resets them - both survive as bank state, stale against
whatever the flags now say. Re-arm both wherever your game
re-establishes its own state.

## Calling convention

Every function is invoked as `EXTERN p fn`, the same as any other DAAD
extern. What differs is what `p` means: rather than passing a value
directly, every toolkit function takes `p` as a FLAG NUMBER and reads or
writes through that flag. A game wanting to add two values still has to
put them in flags first, but the module itself never grows past four
flags no matter how many values a game manipulates - the flag number is
the indirection, not a hardware limit. The exceptions take `p` as a
plain value instead, and each says so where it is documented: fns 76
and 78 to 81, and fn 84's window number.

Printing functions write through `SVC_PUTCHAR` into whatever DAAD window
the author has currently selected with `WINDOW`, the same convention a
status-line process already uses. The module needs no tilemap geometry
and no width probe of its own.

## Flags

- 248 - print width. 0 means no padding. Bit 7 selects zero-pad instead
  of space-pad for functions that print with a fixed field width.
- 249 - second operand. Depending on the function, this is read either
  as an immediate value or as a flag number holding one.
- 250 - the HIGH byte of a 16-bit result. Only fn 79 writes it. The
  picker's pool size is module state, not this flag.
- 251 - the result. Where a function returns a value (a count, an
  object number, a comparison, an overflow flag), it goes here. Failure
  is reported through the carry flag, never through this flag.

## Number printing

    EXTERN n 70    ; print flag n as decimal 0-255
    EXTERN n 71    ; print flags n/n+1 as decimal 0-65535, low byte first

Flag 248 sets the field width, so a status readout lines up:

    LET 248 5      ; five columns, space-padded
    LET 248 133    ; five columns, zero-padded (128 + 5)
    LET 248 0      ; no padding at all

A number wider than the field prints in full rather than being truncated.
Fn 71 does nothing if n is 255, which has no n+1.

Digits print through the DAAD word wrapper, which buffers until a space,
a newline, a full window width or a window switch. A number printed as
the LAST thing in an entry, with no following text and no WINDOW switch,
stays buffered and invisible until something else flushes it. Follow a
final number with a MES containing at least a space or a newline, or a
WINDOW switch - or set a print target window (fn 84, below), whose own
restore switch flushes it for you.

## 16-bit arithmetic on flag pairs

Every pair is low byte first.

    EXTERN n 72    ; [n,n+1] += flag 249 as an immediate value
    EXTERN n 73    ; [n,n+1] -= flag 249 as an immediate value
    EXTERN n 74    ; compare [n,n+1] against the pair at flag 249
    EXTERN n 75    ; [n,n+1] += the pair at flag 249

Fns 72, 73 and 75 leave 1 in flag 251 if the result overflowed or went below
zero, and 0 if it did not. The stored value WRAPS in that case rather than
clamping, so test flag 251 if it matters.

Fn 74 writes 0, 1 or 2 to flag 251 for less, equal and greater, and changes
neither pair:

    LET 249 102
    EXTERN 100 74
    > _  _    EQ  251 2
              ; true when the pair at 100/101 is greater than the pair at 102/103

This is what makes scores, money and move counts above 255 tractable, and it
pairs with the clock module's 16-bit rate.

## Object queries

These four read the interpreter's own object table, so they see the live
game: every walk runs over the objects the database actually declares,
and CREATE, DESTROY, GET and WEAR are all reflected at once.

    EXTERN loc 78    ; count objects at location loc into 251
    EXTERN noun 80   ; first object with that noun into 251
    EXTERN bit 81    ; count objects with extended attribute bit set, into 251
    EXTERN 0 79      ; total carried + worn weight into 250/251

Unlike the rest of the module, these take `p` as a VALUE, not a flag
number: a location, a noun word id, an attribute bit.

Fns 78, 80 and 81 are CONDITIONS. They fail the entry - the rest of it
does not run, exactly like a failed `AT` or `ZERO` - when there is
nothing to report, so the natural shape is a pair of entries:

    > LOOK _   EXTERN 0 78          ; anything at location 0?
               MES "Things here: "
               EXTERN 251 70        ; fn 70 takes a FLAG number: print 251
               MES " "
               DONE
    > LOOK _   MES "Nothing here."
               DONE

Precisely:

- Fn 78 counts objects whose location byte is `loc`. The DAAD
  pseudo-locations work as written: 254 carried, 253 worn, 252 not
  created. Count into 251; CF set (entry fails) when it is zero.
- Fn 80 finds the LOWEST-numbered object whose noun word id is `noun`,
  into 251; CF set when none matches, and 251 is 0 in that case. Object
  0 is a legitimate answer, so a bare `EQ 251 0` cannot tell "found
  object 0" from "found nothing" - the pass/fail of the entry is the
  discriminator, not the flag.
- Fn 81 counts objects carrying extended attribute `bit`, 0 to 15, into
  251; CF set when it is zero. A bit above 15 is refused the same way:
  251 = 0 and CF set.
- Fn 79 is an ACTION - it always passes - and is the one that writes
  two flags: the total weight of everything carried or worn, 251 = LOW
  byte and 250 = HIGH byte. Flag 251 alone is the answer for any game
  whose total stays under 256. Note the order is HIGH-then-low across
  250/251, which is not fn 71's low-first pair, so `EXTERN 250 71` will
  NOT print it - copy the two bytes into a pair of your own first, or
  test 250 for zero and print 251.

Fn 79 counts container contents too, on the interpreter's own rules: an
object with the container attribute adds the weight of every object
whose location is that object's NUMBER, recursively, to a depth of 10.
A container of ZERO own weight is the manual's "magic bag" and adds
nothing for its contents at all.

One deliberate difference from the engine's own WEIGH and WEIGHT
condacts: those saturate at 255, both per container and in the total.
Fn 79 does not saturate anywhere - that is what the 16-bit 250/251 pair
is for. A game whose carried weight can exceed 255 gets a true figure
here and a clipped one from WEIGHT.

Attribute numbering matches `HASAT`: bit 0 is the attribute `HASAT 0`
tests. (Inside the object table the two bytes are held in flag order,
attributes 0-7 in one and 8-15 in the other; the module resolves that,
so nothing about it reaches the author.)

## Random without repeat

    EXTERN n 76      ; arm the picker with a pool of n items, 1 to 64
    EXTERN 0 77      ; pick an unused index 0..n-1 into 251

Fn 76 sets the pool size and clears the used-mask. n = 0 or n above 64
is refused: CF set and the previous pool left untouched.

Fn 77 is a CONDITION. It picks an index that has not come up since the
last fn 76, writes it to 251 and passes. When every index in the pool
has been used - or the pool is unarmed - it FAILS with 251 = 0, which is
what makes the exhaustion case writable without a counter of your own:

    > _  _   EXTERN 0 77
             MES "The wind carries a voice: "
             ; user message 40 + the index, via V3 indirection
             DONE
    > _  _   EXTERN 6 76          ; all six used - start the cycle again
             DONE

Two things differ from the collection design note this module grew from,
both on purpose:

- Exhaustion does NOT auto-reset the mask. The older sketch restarted
  the cycle silently; a condition that never fails cannot tell a game
  the pool ran out, and a game that wants the old behaviour writes the
  `EXTERN n 76` above, which is one line and visible.
- The used-mask lives in the module, not in flags the author names, so
  it is NOT part of a SAVE. A LOAD restores the flags and leaves the
  picker untouched: the same pool size and the same used-mask as before,
  now stale against the restored game. Re-arm with `EXTERN n 76`
  wherever your game already re-establishes state after a LOAD.

## Time formats

    EXTERN n 82    ; print flags n/n+1 as HH:MM
    EXTERN n 83    ; print flags n/n+1, a 16-bit second count, as MM:SS

Both print a fixed two-digit field per part and ignore flag 248. Fn 82 reads
two separate byte flags, which is how the clock module keeps its hour and
minute, so `EXTERN 224 82` prints the in-game clock. Fn 83 reads a 16-bit
count low byte first, so `EXTERN 229 83` prints a real-seconds timer from the
timer module. A minutes field above 99 prints in full rather than being
truncated.

## CALL slots

The four printing routines are also reachable by DAAD's CALL condact, which
skips the EXTERN dispatch. CALL carries no parameter, so the flag number comes
from flag 249:

    LET 249 100
    CALL 17 192     ; slot 1: print flags 100/101 as decimal

| Slot | Address | Does the same as |
|---|---|---|
| 0 | `CALL 14 192` | `EXTERN n 70` |
| 1 | `CALL 17 192` | `EXTERN n 71` |
| 2 | `CALL 20 192` | `EXTERN n 82` |
| 3 | `CALL 23 192` | `EXTERN n 83` |

Slot n sits at $C00E + 3n. The addresses are fixed in every build shape -
standalone, combined and any subset - so they are safe to hard-code, provided
toolkit is in the build. If it is not, the slots still exist at those
addresses but jump to a bare RET and print nothing. Never CALL a routine
address instead; those move whenever any other module is edited.

## Print target window

    EXTERN w 84    ; set the toolkit print target: 1-7 selects a window, 0 clears it

Unlike every other function in this module, fn 84's parameter is the window
number itself, not a flag number. While the target is nonzero, fn 70, 71, 82,
83 and the four CALL slots bracket their own output - select the target
(parking whatever window was current), print, restore what was current - so
the author never brackets with `WINDOW` and never hits the flush trap a bare
number left buffered would otherwise fall into. p1 = 0 or p1 > 7 clears the
target; 8-255 is never masked onto a real window.

Two behaviours matter before relying on it:

- Selecting the target flushes the CURRENT window's pending word first, the
  same as any `WINDOW` switch. `MES "Score " / EXTERN 100 71` with a target
  set puts "Score" in the game window and the number in the status window,
  not side by side - set the target back to 0 (`EXTERN 0 84`) before a print
  that mixes MES text and a number inline.
- The More prompt is reachable in the TARGET window: an exact line fill
  wraps there exactly as it would in any other window (the print path's
  glyph wrap), which a one-row status window has no room to satisfy. Size
  the status window for what it will actually hold.

## A status line

Geometry is still the author's job, set up once - its own `WINAT`/`WINSIZE`,
PAPER and INK - the same as any other window. Fn 84 does not position or
clear anything: it only means a print issued from anywhere lands in the
target window and is flushed at once by the restore, with no `WINDOW`
bracket and no pending-word trap to worry about. A repaint still needs an
explicit `WINDOW n` and `CLS`, the same as it always did.

Add the geometry, and the one-time `EXTERN 2 84` that arms the target, to
wherever your game already sets up its own start-of-game state - the same
`AT 0` turn check PRO 0, the main location loop, typically uses:

    > _  _   AT 0                    ; starting the game?
             WINDOW  2
             WINAT   16 0
             WINSIZE 1 40
             WINDOW  1
             EXTERN  2 84             ; target window 2 from here on

A dedicated process repaints the whole line on demand, exactly as it would
without fn 84 at all:

    /PRO 20
    > _  _   WINDOW 2
             CLS
             MES "Score "
             LET 248 5
             EXTERN 100 71     ; 16-bit score at flags 100/101
             MES "  Time "
             EXTERN 224 82     ; the clock module's HH:MM
             WINDOW 1
             DONE

With the target armed, the two `EXTERN` calls above still self-bracket -
they select window 2, which is already current, so the bracket is a no-op.
That is not what makes this entry work; it would print exactly the same way
with no target set at all. What fn 84 actually buys is everywhere ELSE in
the game: a separate entry, in whatever OTHER process already reacts to the
score changing, can update the value with no `WINDOW` at all, and it shows
up in the status window immediately - this is not part of `/PRO 20` above:

    > _  _   LET    249 1
             EXTERN 100 72     ; score += 1, wherever that happens in play
             EXTERN 100 71     ; ...and the status window updates at once
             DONE

That bare `EXTERN 100 71` prints straight into window 2 and restores
whatever window was current - but it does not reposition or clear anything
first, so it APPENDS after whatever `/PRO 20` last painted there. It is a
stopgap between repaints, not a replacement for one; the next `/PRO 20` pass
cleans it up.
