# toolkit

A collection of small pure-logic helpers: decimal printing, 16-bit
arithmetic and time formatting. Unlike `clock` or `timer`, toolkit has no
frame hook and no arming call - every function runs to completion inside
the single foreground `EXTERN` that calls it, and there is nothing for a
LOAD to restore. The module implements nine of its functions: fn 70 and
fn 71 for decimal printing, fn 72 to fn 75 for 16-bit arithmetic on flag
pairs, fn 82 and fn 83 for time formatting, and fn 84 to set a print
target window. Four of them - fn 70, 71, 82 and 83 - are also reachable
through DAAD's CALL condact, a second entry point alongside the existing
EXTERN dispatch (see CALL slots below). Fn codes 76 to 81 also belong to
this module's range - object queries and a random-without-repeat picker;
see the Object queries section below.

## Calling convention

Every function is invoked as `EXTERN p fn`, the same as any other DAAD
extern. What differs is what `p` means: rather than passing a value
directly, every toolkit function takes `p` as a FLAG NUMBER and reads or
writes through that flag. A game wanting to add two values still has to
put them in flags first, but the module itself never grows past four
flags no matter how many values a game manipulates - the flag number is
the indirection, not a hardware limit.

Printing functions write through `SVC_PUTCHAR` into whatever DAAD window
the author has currently selected with `WINDOW`, the same convention a
status-line process already uses. The module needs no tilemap geometry
and no width probe of its own.

## Flags

- 248 - print width. 0 means no padding. Bit 7 selects zero-pad instead
  of space-pad for functions that print with a fixed field width.
- 249 - second operand. Depending on the function, this is read either
  as an immediate value or as a flag number holding one.
- 250 - count or pool size, for functions that need one. Reserved; no
  function uses it yet.
- 251 - result and status. Where a function returns a value, it goes
  here, alongside any status the function needs to report.

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
`AT 0` turn check a location's own process table typically uses:

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
