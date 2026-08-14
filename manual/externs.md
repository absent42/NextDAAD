# Externs

An extern is a piece of machine code you write yourself and ship
alongside your database. The interpreter loads it at boot and calls into
it from three places in your source: `EXTERN`, `CALL`, and once per
frame through an interrupt hook. Nothing here is required - a game with
no extern builds and plays exactly as it always did.

Reach for one when a DSF condact genuinely cannot do the job: custom
per-frame animation, reading or writing your own file on the SD card,
a calculation too fiddly for `LET`, or driving hardware the condact set
does not expose. Anything a condact already does, do with the condact -
an extern costs you a Z80 assembler and the discipline this chapter
describes.

## The GAME.XBN file

Your extern ships as `GAME.XBN`, a single binary file placed beside
`GAME.DDB` in the game directory. The interpreter probes for it once at
boot, right after the database loads. If the file is absent, externs are
simply off - no error, no cost, the game plays as if the feature did not
exist.

One `GAME.XBN` serves the whole game. It loads once and survives every
part switch in a [multi-part game](multi-part-games.md); there is no
per-part extern. It is not part of a save game - see
[Save and load](#save-and-load) below for what that means for you.

## Building an XBN

Assemble your extern with sjasmplus against `xbn.inc`, the include the
authoring kit ships at its root. Three things every XBN source file
needs:

```
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    ORG XBN_ORG
    XBN_HEADER ext_main, int_tick
```

`XBN_ORG` is `$C000` - every XBN is assembled to run at that address,
and the interpreter maps it there for you at call time. `XBN_HEADER`
writes the ten-byte header the loader validates (see
[XBN format](reference/xbn-format.md) for the exact layout); pass the
label of your `EXTERN`/`CALL` entry point and your frame-hook entry
point, or `0` for either one you do not need. An interrupt-only extern
(entry `0`, hook set) is legal, and so is the reverse.

End your source with a label named `xbn_end` right after your last byte,
and a `SAVEBIN` that writes the whole thing out:

```
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
```

Copy the resulting `GAME.XBN` next to `GAME.DDB` on the card. The whole
binary, header included, must fit in 16384 bytes - see
[Limits](reference/limits.md).

### The ticker example

The authoring kit's `examples\ticker\` folder is a complete, working
XBN worth reading start to finish before you write your own: a
foreground `EXTERN` call fetches a database message with `SVC_GETMSG`,
copies it into the extern's own memory, and a `#int` hook ticks it out
one character per frame along the bottom row of the tilemap. Its own
`README.md` covers how to build it and wire it into a DSF; the source
comments walk through every decision, including the one mistake it is
built to guard you away from - see
[SVC_GETMSG's staging semantics](#services) below. It is the same code
this chapter's examples are drawn from.

## The EXTERN contract

`EXTERN p1 fn` (and its three-parameter V3 form) calls your extern's
entry point with the second parameter as a dispatch selector, the way
classic DAAD externs always worked. Three function codes are reserved by
the interpreter itself and never reach your code: 3 is `XMESSAGE`, 4 is
`XPART`, 7 is `XUNDONE`. Every other code your database can compile -
0, 1, 2, 5, 15, and everything from 16 upward - forwards straight to
your extern's entry point when one is loaded, and behaves exactly as it
did before externs existed (a harmless no-op) when it is not. That is
what makes it safe to ship a database written against an XBN to a
player who has none: nothing crashes, nothing errors, the `EXTERN` calls
that would have reached your code simply do nothing.

Registers on entry to your extern's `EXTERN`/`CALL` entry point:

| Register | Holds |
|----------|-------|
| A | first parameter (also in B) |
| B | first parameter |
| C | function code (second parameter - your own dispatch selector) |
| HL | address of the flag named by the first parameter (`flags + A`) |
| DE | address of the object entry named by the first parameter (`objTable + A*6`) |
| IX | flags base ($A200, a frozen address - see [Flags and objects](#flags-and-objects)) |
| IY | undefined |

A `CALL` entry (see below) gets the same IX; A, B, C, HL and DE are
undefined, since a `CALL` carries no parameters.

Return with a plain `RET`. You may clobber A, BC, DE, HL, IX, IY and
both alternate register sets - the interpreter saves nothing across the
call beyond what it needs for its own bookkeeping. There is no result
register and no error code the interpreter reads back: write whatever
you want the rest of the game to see into a flag, and test that flag
with an ordinary condact after the `EXTERN` call. Keep stack usage
modest - your extern runs on the interpreter's own stack, and a couple
of hundred bytes of headroom is a safe budget.

Unlike some classic DAAD interpreters, this one does not let an extern
consume extra bytes inline from the condact stream - there is no way to
read "the next byte after this EXTERN" the way some machines' externs
could. Pass extra data through flags instead: `LET` a value before the
`EXTERN` call, or build a lookup table in your XBN indexed by the
function code.

## CALL

`CALL lsb msb` assembles a 16-bit address from its two byte arguments
and, if that address falls inside your loaded XBN's extent
(`$C000` up to but not including the end of your binary), runs the code
there. An address outside that range, or no XBN loaded at all, is a
safe no-op - the same behaviour `CALL` always had before extern support
existed.

`CALL` gives you a second, parameter-free way into your own code:
useful for a fixed jump table of small routines you want to reach
directly by address rather than by dispatching on a function code. IX
still points at the flags base on entry; A, B, C, HL and DE carry
nothing meaningful.

## The #int hook

If your XBN's header names an interrupt entry point, the interpreter
calls it once every frame, at 50Hz, from inside its own frame interrupt.
This is real interrupt-context code, and the rules that come with that
are not optional:

- **Keep it short.** Well under one frame's worth of time. An overrun
  delays the next audio tick.
- **Never enable interrupts.** Do not execute `EI`.
- **No DMA.** Do not use the zxnDMA - it contends with video and sample
  streaming DMA already in flight.
- **No file IO and no service calls.** Every v1 service (see below) is
  foreground-only; none of them may be called from the hook.
- **Never install your own interrupt handler.** The IM2 vector table is
  writable RAM, but your code only exists in the address space while
  its own bank is mapped - a self-installed vector is a guaranteed
  crash the moment your bank is unmapped again. The `#int` hook is the
  only legal interrupt-context entry point into your code.
- **Direct tilemap writes are fine, except during video playback with an
  audio track.** Writing to the tilemap at `$6000` from inside the hook
  is legitimate and race-free for as long as no such clip is playing -
  the interrupt handler never remaps that window on its own account.
  But while a video clip with an audio track is playing, the
  interpreter itself borrows that same window as the clip's audio feed
  for the clip's whole duration, and the hook keeps firing throughout.
  A tilemap write from the hook during that span lands in the audio
  buffer instead and corrupts the clip's sound. Pause or disarm your
  ticker around `PLAY` if it writes the tilemap.
- **Mind video playback.** Video decode is bound by how many CPU cycles
  it can spend per frame; heavy work in your hook while a clip is
  playing will visibly degrade it. You own both the hook and the
  decision to run one during a cutscene - the interpreter does not stop
  you.

On entry, IX points at the flags base, exactly as it does for an
`EXTERN` call. Every other register is undefined, and the interpreter
preserves nothing across the call for you - do not rely on any register
holding a value from a previous frame.

The hook runs whether or not there is anything for it to do, every
frame, for as long as the game plays. Test a flag or a variable of your
own first and return immediately when there is nothing to do - the
ticker example's `int_tick` is one load-and-test when idle, and that
idiom is worth copying directly.

## Services

The interpreter exposes ten small routines through a fixed jump table at
a frozen address, `XBN_API` (`$BEC8`). `xbn.inc` binds a symbol to each
row, so you call them by name:

| # | Symbol | In | Out |
|---|--------|----|----|
| 0 | `SVC_VERSION` | - | A = API version |
| 1 | `SVC_PUTCHAR` | A = character | - |
| 2 | `SVC_PUTS` | HL = ASCIIZ string (may live in your own bank) | - |
| 3 | `SVC_FOPEN` | IX = ASCIIZ filename, B = mode | A = handle, or CF set + error |
| 4 | `SVC_FREAD` | A = handle, IX = buffer, BC = length | BC = bytes read, or CF set + error |
| 5 | `SVC_FWRITE` | A = handle, IX = buffer, BC = length | CF set + error on failure |
| 6 | `SVC_FSEEK` | A = handle, BCDE = offset | CF set + error on failure |
| 7 | `SVC_FCLOSE` | A = handle | - |
| 8 | `SVC_RANDOM` | - | A = random byte |
| 9 | `SVC_GETMSG` | A = user message number | HL = buffer, BC = length, or CF set + A = $FF |

Call a service exactly like any other subroutine - `call SVC_PUTCHAR`
and so on. Every row preserves your XBN bank's own mapping across the
call: whatever a service does internally, your code resumes exactly
where it left off, with its own memory still mapped underneath it.

A few things worth knowing about specific rows:

- **`SVC_PUTCHAR` and `SVC_PUTS` print through the current DAAD window.**
  Colours, word wrapping and the `More...` prompt all behave exactly as
  they do for ordinary game text, because that is the same print path
  they use. `SVC_PUTS` flushes the word wrapper before returning, so a
  buffered final word is never left stranded on screen.
- **`SVC_RANDOM` returns a raw byte**, uniformly distributed 0-255. It
  is not the 1-100 range `CHANCE` uses - scale or mask it yourself if
  you need a narrower range.
- **File services are thin wrappers over the same esxDOS machinery the
  interpreter itself uses** for save games and asset loading. `mode` for
  `SVC_FOPEN` is the raw esxDOS open mode byte; the error convention
  throughout is esxDOS style - carry flag set, A holds the error code.
  Like the underlying wrappers, every file service may clobber AF, BC,
  DE, HL and IX; only the columns the table above lists are meaningful
  on return.
- **`SVC_GETMSG` decodes a database user message into a shared,
  interpreter-owned buffer and hands you its address and length.** This
  is the one service with a lifetime rule attached, and it matters: the
  buffer is only valid until the *next* service call of any kind, or
  until the next `SAVE`, `LOAD`, `RAMSAVE` or `RAMLOAD` - because it is
  the same resident memory that machinery uses for its own staging. If
  your extern needs the text to outlive the call that fetched it (the
  ticker example does, since its `#int` hook reads the text frame by
  frame long after the fetch returned), copy it into memory your own
  bank owns before doing anything else. The buffer is capped at 256
  bytes; a longer message is truncated, and the returned length in BC
  always matches what actually landed in the buffer. The bytes are
  returned exactly as the database stores them - control codes intact,
  and the `_`/`@` object-name substitution *not* expanded, since there
  is no object context to substitute at fetch time. A message number
  outside the database's range returns with the carry flag set and
  A = `$FF`.

### Versioning

`SVC_VERSION` reports the API version your interpreter build supports.
The service table is append-only and its address is frozen from the
first shipping release: existing rows never move and never change
signature, so a game built against this version of `xbn.inc` keeps
working unmodified on every future NextDAAD release. New services, when
they arrive, are new rows at the end of the table with a version bump -
check `SVC_VERSION` yourself if you ever call a service your `xbn.inc`
did not ship with, to fail gracefully on an older interpreter rather
than jumping into whatever used to live at that address.

## Flags and objects

Your extern reads and writes DAAD flags and object state directly, with
no service in between - the interpreter simply exposes the memory.

- **Flags 0-127** are reachable with an 8-bit signed displacement off
  `IX`, which the interpreter always points at the flags base on entry:
  `ld a, (ix+n)` for flag `n`. This only reaches half the flag space -
  `IX+n` cannot express a displacement past 127.
- **Flags 128-255** need absolute addressing instead: `XBN_FLAGS+n`,
  where `XBN_FLAGS` (`$A200`, another frozen anchor `xbn.inc` defines)
  is the same base `IX` points at. `ld a, (XBN_FLAGS+200)` reads flag
  200 directly.
- **Flags 0-63 are system flags** with meanings the interpreter and the
  parser already assign - the player's location, the carried-object
  count, the last object referenced, and so on. Reading one is fine;
  writing one changes engine behaviour, not just your own bookkeeping,
  so treat that range as read-mostly unless you specifically mean to
  affect the parser. Flags 64-255 are yours to use freely.
- **The object table** sits at `XBN_OBJTABLE` (`$A300`, also frozen),
  one six-byte entry per object: location at offset 0, weight and
  container/wearable attribute bits at offset 1, two bytes of extended
  attributes at offsets 2-3, then the noun and adjective vocabulary IDs
  at offsets 4 and 5. `DE` on entry to an `EXTERN` call already points
  at the entry for the object named by the first parameter, so
  `ld a, (de)` reads that object's location without any arithmetic of
  your own.

## Save and load

The extern bank itself is never part of a save game. `SAVE`, `LOAD`,
`RAMSAVE` and `RAMLOAD` persist flags and object state exactly as they
always did - nothing about your XBN's own code or data changes because
of them. Practically, that means:

- **Anything you need to survive a `LOAD` belongs in a flag**, not in a
  variable inside your XBN's own memory. A `LOAD` restores flags to
  whatever they held at save time; it does not touch your bank at all,
  so a value you kept only in your own RAM is left exactly as it was
  before the load - stale, not restored.
- **Bank-resident state does survive within a session**: across
  `EXTERN`/`CALL` invocations, across part switches, and across
  `RESTART`. It is only a `LOAD` (or a `RAMLOAD`) that leaves it
  unsynchronised with the flags the player just restored.
- **There is no dedicated init entry.** Initialise your extern's own
  state from an ordinary `EXTERN` call in your startup process, the way
  classic DAAD games initialised externs from `PRO 6`.
