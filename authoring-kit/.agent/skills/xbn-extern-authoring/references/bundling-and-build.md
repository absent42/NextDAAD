# Bundling and build

A game loads exactly ONE `GAME.XBN`. You never merge sources by hand.

## Building one module

Every folder under `externs\` has a `build.ps1`. Run it from the folder:

    .\build.ps1

It assembles the folder's `.asm` with the kit root on the include path
(`-I <kit root>`, which is what makes `INCLUDE "xbn.inc"` resolve) and
rewrites `GAME.XBN` in place. Commit the source and the binary together: they
are checked against each other.

It finds sjasmplus in this order, from `lib\resolve-sjasmplus.ps1`:

1. the `-SjasmPlus` parameter, if you pass a path;
2. the kit's own `tools\sjasmplus\sjasmplus.exe`, or one nested subfolder
   deeper, since a zip extract can leave it either way;
3. `sjasmplus.exe` on `PATH`.

If none of those find it, download it from
https://github.com/z00m128/sjasmplus and extract it into `tools\sjasmplus\`.
You only need an assembler to CHANGE a module - every folder ships a prebuilt
`GAME.XBN`.

## Building a subset

From the kit root:

    EXTERNS.BAT ticker fade

That writes a `GAME.XBN` holding only the modules you name to the kit root,
beside `BUILD.BAT`. The names it accepts are the seven module folders in
`externs\`: `ticker`, `fade`, `hints`, `clock`, `timer`, `realtime` and
`toolkit`.

This route puts one step in front of that ladder: it reads `SJASMPLUSDIR` from
`CONFIG.BAT` (empty by default, which falls back to the kit's `tools\`
folder), turns it into an absolute path, and passes it down as `-SjasmPlus`
only if that path actually exists. That last condition matters - passing it
unconditionally would skip the `PATH` fallback and fail every build for an
author who has sjasmplus on `PATH` but has not downloaded it into the kit.

The subset builder generates a top-level source with the same shape as
`all.asm`: your modules in the order you named them, each `INCLUDE`d, each
wired into both chains. It prints the finished size and how much of the 16384
bytes is left.

## Why all\ exists

`externs\all\` is the whole collection built into one prebuilt binary. It
exists so an author with no assembler still gets every module: copy that one
`GAME.XBN` and use whatever functions you want. An unused module costs nothing
at run time - its share of the frame hook is a single load-and-test and its
flags stay untouched until the game invokes it - so a game shipping `all\` and
using only the fade pays for only the fade.

`all\` follows the same four-file folder contract as every other module: one
source (`all.asm`), `GAME.XBN`, `README.md`, `build.ps1`.

## The all.asm wiring

Adding a module to the combined binary is four edits in `all.asm` and nothing
else moves:

1. **A `DEFINE`.** `DEFINE XBN_HAS_<NAME>` beside the others, above the
   includes. `DEFINE XBN_MODULE` at the top is what suppresses each module's
   own header and `SAVEBIN`.
2. **An ext-chain entry.** Three lines in `all_ext`:

        call xbn_setup
        call myext.ext
        XBN_CHAIN_CAPTURE

   `xbn_setup` rebuilds the documented entry contract (A = B = param1, C = fn,
   HL = flags + param1, DE = objTable + param1*6, IX = flags base) before each
   module call, because modules may clobber everything. `XBN_CHAIN_CAPTURE`
   folds that module's carry into the accumulator IMMEDIATELY after its call,
   since `xbn_setup` clobbers F. The chain returns through
   `XBN_CHAIN_VERDICT`: carry set if any module failed, clear if none did.
3. **An int-chain entry.** Two lines in `all_int`:

        ld ix, XBN_FLAGS
        call myext.int

   `IX` is reloaded per module because it is the only register the hook
   contract documents.
4. **An `INCLUDE`.** `INCLUDE "externs/myext/myext.asm"`, by kit-relative
   path, resolved by the `-I <kit root>` the build passes.

Module ORDER in the chains is pinned, not arbitrary. The subset builder emits
modules in the order you name them, and `all.asm` records the one ordering
constraint the collection has in a comment beside it: the clock's hook runs
before the timer's, so a timer whose in-game-minute deadline expires this
frame can react in the same frame. Do not reorder without a reason and a
comment.

## Scratch claims when combining

`XBN_SCRATCH` is defined by `XBN_SCRATCH_END`, which the TOP-LEVEL source runs
once after its own `xbn_end` - `all.asm` in the combined build, your module's
own `IFNDEF` tail in a standalone one. Claims are offsets from `XBN_SCRATCH`,
chained off `XBN_SCRATCH_FREE` in `xbnmod.inc` so modules never collide: take
the current value as your offset, add a claim comment, bump the value past
your claim. The assert in `XBN_SCRATCH_END` fails the build if the claims
would run past the mapped bank.

## Where GAME.XBN goes

On the card, `GAME.XBN` sits beside `GAME.DDB` in the game directory. Nothing
else is needed: the interpreter probes for it once at boot.

Two ways to get it there:

- **By hand.** Copy a module folder's prebuilt `GAME.XBN` next to your
  `GAME.DDB` on the card. No assembler, no build step.
- **Through the kit's build.** Put a `GAME.XBN` in the kit root, beside
  `BUILD.BAT`. `BUILD.BAT` stages it as-is into `RELEASE\GAME.XBN`, and
  `RELEASE\`'s contents are what you copy to the card. `EXTERNS.BAT` writes
  its subset binary to exactly that spot, so a subset build is picked up by
  the next `BUILD.BAT` with no extra step.

The whole file, header included, must fit in 16384 bytes. The subset builder
prints the headroom left; the loader rejects anything larger, and rejects it
silently in a Release build.

Full detail: the manual's
[One binary, any subset](../../../../docs/externs.html#one-binary-any-subset)
and the collection table in `externs\README.md`.
