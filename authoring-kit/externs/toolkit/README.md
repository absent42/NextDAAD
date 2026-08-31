# toolkit

A collection of small pure-logic helpers: decimal printing, 16-bit
arithmetic and time formatting. Unlike `clock` or `timer`, toolkit has no
frame hook and no arming call - every function runs to completion inside
the single foreground `EXTERN` that calls it, and there is nothing for a
LOAD to restore. The module currently ships four functions: fn 70 and fn
71 for decimal printing, fn 82 and fn 83 for time formatting; the
arithmetic routines described here are still to come.

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

## Time formats

    EXTERN n 82    ; print flags n/n+1 as HH:MM
    EXTERN n 83    ; print flags n/n+1, a 16-bit second count, as MM:SS

Both print a fixed two-digit field per part and ignore flag 248. Fn 82 reads
two separate byte flags, which is how the clock module keeps its hour and
minute, so `EXTERN 224 82` prints the in-game clock. Fn 83 reads a 16-bit
count low byte first, so `EXTERN 229 83` prints a real-seconds timer from the
timer module. A minutes field above 99 prints in full rather than being
truncated.
