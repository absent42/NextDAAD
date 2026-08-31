# toolkit

A collection of small pure-logic helpers: decimal printing, 16-bit
arithmetic and time formatting. Unlike `clock` or `timer`, toolkit has no
frame hook and no arming call - every function runs to completion inside
the single foreground `EXTERN` that calls it, and there is nothing for a
LOAD to restore. This task ships only the module skeleton; no functions
are wired up yet. Later tasks add the fn code dispatch and fill in the
arithmetic, printing and formatting routines described here.

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
