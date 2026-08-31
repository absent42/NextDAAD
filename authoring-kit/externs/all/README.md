# All - the whole collection in one GAME.XBN

A game loads exactly one `GAME.XBN`. This folder holds every extern in the
collection built into a single binary, so you can copy one file to your card
and use any of their functions without an assembler.

To use it: copy this folder's `GAME.XBN` next to your `GAME.DDB`, then add the
DSF lines from whichever module's README you want. Each module documents its
own `EXTERN` condact fn codes, for example `EXTERN n 30` to arm ticker.
Function codes and flags are disjoint across the collection, so modules never
collide.

Modules are dormant until armed. A module you never arm never reads or writes
its flags, so its flag block stays yours.

| Module | fn codes | README |
|---|---|---|
| ticker | 30, 31 | `../ticker/README.md` |
| fade | 40-43 | `../fade/README.md` |
| hints | 50-53 | `../hints/README.md` |
| clock | 60-62 | `../clock/README.md` |
| timer | 63-64 | `../timer/README.md` |

If you would rather ship a smaller binary with only the modules you use, run
`EXTERNS.BAT` from the kit root - see the collection README.

`CALL` targets are slots in a fixed jump table at `$C00A`, not routine
addresses: slot n is at `$C00A + 3n`. Slots whose module is not in the build
return harmlessly.
