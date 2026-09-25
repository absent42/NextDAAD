# Bundling and build

A game loads exactly ONE `GAME.XBN`. You never merge sources by hand.

## Building one module

Every folder under `externs\` has a `build.ps1`, including `transcript\`.
Run it from the folder:

    .\build.ps1

It assembles the folder's `.asm` with the kit root on the include path
(`-I <kit root>`, which is what makes `INCLUDE "xbn.inc"` resolve) and
rewrites `GAME.XBN` in place. Commit the source and the binary together: they
are checked against each other. Every module's `build.ps1` takes an optional
`-SjasmPlus <path>` parameter.

It finds sjasmplus in this order, from `lib\resolve-sjasmplus.ps1`:

1. the `-SjasmPlus` parameter, if you pass a path;
2. the kit's own `tools\sjasmplus\sjasmplus.exe`, or one nested subfolder
   deeper, since a zip extract can leave it either way;
3. `sjasmplus.exe` on `PATH`.

The kit's own `tools\sjasmplus\` folder may ship empty - do not assume its
presence means an assembler is there. If none of the three find one, download
it from https://github.com/z00m128/sjasmplus and extract it into
`tools\sjasmplus\`, or pass `-SjasmPlus` with a path of your own. You only
need an assembler to CHANGE a module - every folder ships a prebuilt
`GAME.XBN`.

## Building a subset

From the kit root:

    EXTERNS.BAT ticker fade ..\mymods\doors

That writes one `GAME.XBN` holding the modules you name to the kit root,
beside `BUILD.BAT`. Each argument is either:

- a bare name - a folder under `externs\`: the eight shipped modules
  (`ticker`, `fade`, `hints`, `clock`, `timer`, `realtime`, `toolkit`,
  `transcript`) or one you dropped there; or
- a path, anything with a `\` or `/` - a folder holding `<folder>.asm`
  (or that `.asm` itself), named after the folder, relative to the
  directory you ran `EXTERNS.BAT` from. It may not reuse a name from
  `externs\`, and must be plain ASCII - sjasmplus cannot open anything
  else.

This route puts one step in front of the assembler ladder: it reads
`SJASMPLUSDIR` from `CONFIG.BAT` (empty by default, which falls back to the
kit's `tools\` folder), turns it into an absolute path, and passes it down
as `-SjasmPlus` only if that path actually exists. That last condition
matters - passing it unconditionally would skip the `PATH` fallback and
fail every build for an author who has sjasmplus on `PATH` but has not
downloaded it into the kit.

The builder (`lib\xbnbuild.ps1`) reads each module's `MODULE` block for its
entry labels at column 0 and its `SCRATCH_SIZE`/`STATE_SIZE` declarations.
It then generates a top-level source with the same shape as `all.asm`:
your modules in the order you named them, each `INCLUDE`d, each wired into
the ext and int chains, with a `DEFINE XBN_HAS_<NAME>` for each. A module
with a `line` label joins the line chain, and one with `out` the output
chain. Any hook makes the header format 3 (`XBN_BEGIN3`), with `0` for a
hook no module has. Declared claims are placed after the collection's and
printed:

    > claim doors scratch +2816 (256), state +10 (4)

It prints the finished size and how much of the 16384 bytes is left.
Mistakes stop the build with one `xbnbuild:` line before anything is
assembled: an unknown name, a missing `int` label, an indented entry
label, or a name used twice. After assembly it also refuses an entry
label or size equate that sjasmplus defined but the scan did not see -
one in an `INCLUDE`d file - and writes nothing. The module's name is the spelling on its
`MODULE` line; the folder may differ from it in case. Run `EXTERNS.BAT`
with no modules for the usage and the module list.

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

This section is for adding a module to the shipped collection. A module
for your own game needs none of it - `EXTERNS.BAT` generates the same
wiring.

`all.asm` already carries a format 3 header - `XBN_BEGIN3 all_ext, all_int,
all_line, all_out` - because the collection includes a hooked module
(`transcript`). `all_line`/`all_out` chain every hooked module's `line`/`out`
the same way `all_ext`/`all_int` chain every module's `ext`/`int`:

    all_line:
        XBN_LINE_ENTER
        XBN_LINE_CALL transcript.line
        XBN_LINE_END
    all_out:
        XBN_OUT_CALL transcript.out
        ret

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
5. **If the module is hooked, a line and/or an out chain entry.** One line
   each in `all_line`/`all_out`:

        XBN_LINE_CALL myext.line
        XBN_OUT_CALL myext.out

   Only needed for a module that declares that hook (`0` in its header for
   the one it does not use needs no chain entry). A module with neither hook
   needs no format 3 header of its own and no chain entries at all - only
   the top-level `all.asm` header has to be format 3, and only because at
   least one included module needs it.

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

`XBN_SCRATCH_FREE`'s value now depends on `TRANSCRIPT_RING`, since the
transcript module's ring buffer is the last scratch claim:
`XBN_SCRATCH_FREE equ 768 + TRANSCRIPT_RING`. `TRANSCRIPT_RING` defaults to
2048 (`IFNDEF` in `xbnmod.inc`) and is a build define, not a module
constant - define it before including `xbnmod.inc` in a standalone build
that needs a bigger ring; the combined collection binary keeps the smaller
default because every scratch claim shares the one 16K bank.

A module outside the collection declares `SCRATCH_SIZE`/`STATE_SIZE`
instead of editing `xbnmod.inc`. The generated source places those claims
after `XBN_SCRATCH_FREE`/`XBN_STATE_FREE` with `xbnmod.inc`'s
`XBN_CLAIM_AT`, in argument order. Its asserts fail the build if a running
total passes the bank end or `XBN_STATE_LEN`. A standalone build does the
same with `XBN_CLAIMS`.

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
