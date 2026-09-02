---
name: xbn-extern-authoring
description: "Authoring reference for NextDAAD XBN externs - Z80 machine code a DAAD game ships as GAME.XBN and the interpreter calls from EXTERN, CALL and a 50Hz frame hook. Use when writing, extending, building or debugging an extern for a NextDAAD game. Covers: the standalone and combinable module source shapes (xbn.inc, xbnmod.inc), registers on entry, the EXTERN carry verdict contract and the result convention, the fifteen-row service table and which four rows the interrupt hook may call, the frozen anchors (the $C000 window, flags at $A200, the object table at $A300, services at $BEC8, CALL slots at $C00E), building a standalone or combined binary, and the mistakes that cost the shipped examples a debugging session."
---

# XBN extern authoring

An XBN extern is Z80 machine code the author writes and ships as `GAME.XBN`
beside `GAME.DDB`. The interpreter probes for the file once at boot and calls
into it from the game's own DSF. With no `GAME.XBN` present, externs are
simply off: no error, no cost, the game plays as if the feature did not
exist - which is what makes a database written against an extern still
shippable to a player who has none.

## What you are writing

- **One binary per game.** One `GAME.XBN` serves the whole game. It loads
  once, survives every part switch, and is never part of a save game. State
  that must survive `LOAD` belongs in a DAAD flag, not in a variable inside
  your bank.
- **Assembled to the `$C000` window.** `XBN_ORG` is `$C000`; the interpreter
  maps your bank there at call time. The whole file, header included, must fit
  in 16384 bytes.
- **Three call sites.** `EXTERN p1 fn` (a condition as well as an action),
  `CALL lsb msb` (a parameter-free action), and a 50Hz `#int` frame hook. The
  fourteen-byte header names two entry addresses - the `EXTERN` entry and the
  hook entry - and either may be `0`. A `CALL` reaches any address inside your
  binary's extent and nowhere else; in a combined binary those addresses are
  the fixed slots at `$C00E`, never routine addresses.

## When to reach for one

Only when a condact genuinely cannot do the job: custom per-frame animation,
reading or writing your own file on the SD card, a calculation too fiddly for
`LET`, or driving hardware the condact set does not expose. Anything a condact
already does, do with the condact.

Check `externs\` first. The kit ships seven ready-made modules - `ticker`,
`fade`, `hints`, `clock`, `timer`, `realtime`, `toolkit` - each with a
prebuilt `GAME.XBN` that needs no assembler, and `externs\all\GAME.XBN` holds
the lot. If one of them already does the job, wire it into the DSF instead of
writing code.

## Workflow

1. **Copy a module folder.** `externs\ticker\` is the minimal working example:
   one `.asm`, `GAME.XBN`, `README.md`, `build.ps1`. Rename the source and the
   `MODULE` name. Pick fn codes and flags that clash with nothing in the
   collection table in `externs\README.md`. See
   `references/module-shape.md` for the folder checklist - the copied
   `build.ps1` assembles a hard-coded file name and the copied `README.md`
   describes the module you copied; rename both.
2. **Write `ext`.** Dispatch on `C` (the fn code), return immediately on
   anything you do not own, and give every exit a deliberate carry: an action
   ends `or a` / `ret`, a condition ends `scf` / `ret` on its one documented
   "no". See `references/calling-contract.md`.
3. **Write `int` only if you need per-frame work.** A collection module always
   has an `int` label even when it is `int: ret`. When idle it must be one
   load-and-test and nothing more, and only four services are legal inside it.
   See `references/services.md`.
4. **Build.** Run the folder's `build.ps1` for a standalone binary, or
   `EXTERNS.BAT ticker fade` from the kit root for a subset. See
   `references/bundling-and-build.md`.
5. **Test with a DSF that exercises both branches of every condition** - one
   entry that passes and one that fails, with the flag poisoned before the
   call that is meant to write it. A condition your test cannot make fail
   proves nothing. See `references/pitfalls.md`.

## Frozen anchors

`xbn.inc` binds a symbol to the first five; the last comes from `xbnmod.inc`'s
`XBN_BEGIN`. None of them move between releases.

| Symbol | Address | What |
|--------|---------|------|
| `XBN_ORG` | `$C000` | Your binary's load and run address |
| `XBN_FLAGS` | `$A200` | Base of the 256 DAAD flags; `IX` points here on entry |
| `XBN_OBJTABLE` | `$A300` | Object table, `OBJ_SIZE` (6) bytes per entry |
| `XBN_NUMOBJ` | `$A900` | Object count, one byte; walk `0` to `(XBN_NUMOBJ) - 1` |
| `XBN_API` | `$BEC8` | Service jump table, fifteen three-byte `JP` rows |
| `xbn_call_table` | `$C00E` | Combined binaries only: eight `CALL` slots, slot n at `$C00E + 3n` |

Flags 0-127 are reachable as `(ix+n)`; flags 128-255 need `XBN_FLAGS+n`.
Flags 0-63 are system flags the parser and interpreter already own: read them
freely, write them only when you mean to change engine behaviour. Flags 64-255
are yours, minus the collection's reserved band 224-251 if you ship alongside
a collection module.

## Reference Files

Load the one the work needs.

### Module shape
**File**: [references/module-shape.md](references/module-shape.md)
- The standalone and combinable source shapes, the ticker skeleton, registers
  on entry, the `int` label rule, fn/flag disjointness, and what a publishable
  folder must contain.

### Calling contract
**File**: [references/calling-contract.md](references/calling-contract.md)
- Condition semantics and the done-state edge, the guard-first idiom, the
  extern-`CHANCE` worked example, the result convention, what never fails an
  entry, `CALL` slots, and how parameters reach your code.

### Services
**File**: [references/services.md](references/services.md)
- One line per service row with its hook rule, then the rules that bite:
  hook-safe rows, frame waits, the palette interlock, `SVC_BUSY` during
  clips, `SVC_GETMSG`'s buffer lifetime, `SVC_WINDOW`'s flush, `SVC_PALREAD`'s
  bank select, and the version check.

### Bundling and build
**File**: [references/bundling-and-build.md](references/bundling-and-build.md)
- `build.ps1` and how it finds sjasmplus, `EXTERNS.BAT` subsets, why `all\`
  exists, the `all.asm` wiring a module needs, scratch RAM claims, and where
  `GAME.XBN` goes on the card.

### Pitfalls
**File**: [references/pitfalls.md](references/pitfalls.md)
- Twelve mistakes that have already cost someone a debugging session, each as
  the lesson and the rule it produced. Read this before writing a hook.

## The manual

The kit's own manual is the authority; these references summarise it and link
back. Read the pages themselves when a detail matters.

- [Externs chapter](../../../docs/externs.html) - the full contract, the
  worked examples, the collection.
- [XBN format reference](../../../docs/reference/xbn-format.html) - the
  header, the loader's validation order, the complete service table with
  clobbers, the frozen anchors.
- [Changes](../../../docs/changes.html) - what moved at format 2 and what a
  binary built against an older include needs.
