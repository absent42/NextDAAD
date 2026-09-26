# All - the collection in one GAME.XBN

A game loads exactly one `GAME.XBN`. This folder holds every extern in the
collection except transcript, built into a single binary, so you can copy
one file to your card and use any of their functions without an assembler.

Transcript is NOT in this binary - it is the one module the collection
leaves out. The loader arms the output hook tap for any binary whose
header names one, whether or not the module is recording, so a binary
carrying that hook costs every game that loads it on every printed
character. With no hooked module here, this binary carries a plain
format 2 header, which any interpreter version loads; playername's
`SVC_GETLINE` and ticker's `SVC_PAIR`/`SVC_FITWORD` need API 3, each
module checking the version itself, not the loader. Ship
`../transcript/GAME.XBN` on its own, or fold it into an
`EXTERNS.BAT` subset, only in a game that means to record.

To use it: copy this folder's `GAME.XBN` next to your `GAME.DDB`, then add the
DSF lines from whichever module's README you want. Each module documents its
own `EXTERN` condact fn codes, for example `EXTERN n 30` to arm ticker.
Function codes and flags are disjoint across the collection, so modules never
collide.

Modules stay inert until the game invokes them - an arming call for the
modules that use one, or simply never being EXTERNed for the ones that
don't. A module the game never invokes never reads or writes its flags, so
its flag block stays yours.

| Module | fn codes | README |
|---|---|---|
| playername | 20-23 | `../playername/README.md` |
| ticker | 30-38, 39 type message at cursor | `../ticker/README.md` |
| fade | 40-43 | `../fade/README.md` |
| hints | 50-53 | `../hints/README.md` |
| clock | 60-62 | `../clock/README.md` |
| timer | 63-65 | `../timer/README.md` |
| realtime | 66-69 | `../realtime/README.md` |
| toolkit | 70-84 | `../toolkit/README.md` |

If you would rather ship a smaller binary with only the modules you use, run
`EXTERNS.BAT` from the kit root - see the collection README.

`CALL` targets are slots in a fixed jump table at `$C00E`, not routine
addresses: slot n is at `$C00E + 3n`. Slots whose module is not in the build
return harmlessly.
