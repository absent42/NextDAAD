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
writes the fourteen-byte version 2 header - magic, version, the two
entry points, the size and four reserved bytes that must stay zero - and
the loader checks every one of them (see
[XBN format](reference/xbn-format.md#header) for the exact layout); pass
the label of your `EXTERN`/`CALL` entry point and your frame-hook entry
point, or `0` for either one you do not need. An interrupt-only extern
(entry `0`, hook set) is legal, and so is the reverse.

End your source with a label named `xbn_end` right after your last byte,
and a `SAVEBIN` that writes the whole thing out:

```
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
```

A collection module uses `xbnmod.inc`'s `XBN_BEGIN` instead of
`XBN_HEADER`; see [the collection](#one-binary-any-subset).

Copy the resulting `GAME.XBN` next to `GAME.DDB` on the card. The whole
binary, header included, must fit in 16384 bytes - see
[Limits](reference/limits.md).

### The ticker example

The authoring kit's `externs\ticker\` folder is a complete, working
XBN worth reading start to finish before you write your own: a
foreground `EXTERN` call fetches a database message with `SVC_GETMSG`,
copies it into the extern's own memory, and a `#int` hook ticks it out
in a field the game places with fns 32-34, in the colours of fns 35-36,
typed or scrolled (fn 37) at the speed of fn 38 - in either text width,
asking `xbn_width` every frame while armed so a `GFX n 18` switch
mid-message just carries on at the new width, and checking `SVC_BUSY`
first so it stays silent while a video clip owns the tilemap window. Its
arm call (fn 30)
is a condition: an unavailable message number fails the entry instead
of arming nothing, and it resolves its colours through `SVC_PAIR`
before it fetches the message - the reason is in the source. It ships
with a prebuilt `GAME.XBN` beside the source, so you can try it on a
card without assembling anything. Its own `README.md` covers how to
build it and wire it into a DSF; the source comments walk through every
decision, including the one mistake it is built to guard you away from
- see [SVC_GETMSG's staging semantics](#services) below. It is the same
code this chapter's examples are drawn from.

### The fade example

The kit's second worked example, `externs/fade`, fades the Layer 2
picture to any RRRGGGBB colour and back for narrative beats. Beyond the
ticker example's XBN mechanics, it demonstrates reading the palette
back through `SVC_PALREAD`, the palette interlock a hook must hold
before it writes, a frame-gated wait on `SVC_FRAMES`, the
register-select save/restore bracket around shared indexed registers,
and foreground precompute feeding a cheap interrupt hook. It ships with
a prebuilt `GAME.XBN` beside the source, so you can try it on a card
without assembling anything, and its own `README.md` covers building it
and wiring it into a DSF.

The recommended sequence for a scene change behind a fade, buffered so
the new picture never flashes onto screen mid-fade:

```
EXTERN 0 40   ; fade out to the target colour
EXTERN 0 43   ; wait
PICTURE @room ; CONDITION - aborts the entry on missing art, leaving
              ; the draw target untouched
GFX 0 4       ; open buffer mode - AFTER the PICTURE condition, so a
              ; failing PICTURE never strands buffer mode with
              ; GFX 0 3 unreached
DISPLAY 0     ; pixels + palette staged; screen untouched
EXTERN 0 42   ; read the staged palette (SVC_PALREAD, other bank),
              ; rebuild the fade tables, solid both banks
GFX 0 2       ; reveal: flip the surface; every palette is solid
GFX 0 3       ; close buffer mode; drawing targets the screen again
EXTERN 0 41   ; fade up to the new picture
EXTERN 0 43
```

Three rules keep this sequence honest:

- **`PICTURE` before `GFX 0 4`.** `PICTURE` is a condition - it aborts
  the entry on missing or unloadable art (this interpreter's PICTURE
  has no darkness handling of its own). Opening buffer mode before
  that condition runs would strand it open on an abort, since the
  aborted entry never reaches the `GFX 0 3` that would have closed it.
- **No reveal while a fade is still stepping.** Do not run `GFX 0 2` or
  `GFX 0 3` between starting a fade (`EXTERN 0 40`/`41`) and its
  completion - wait on `EXTERN 0 43` or flag 240 first. The palette
  interface is shared hardware: a still-stepping fade overlapping the
  reveal can land the interrupt hook's write mid-mirror and corrupt one
  palette entry.
- **Fade functions are actions, never conditions.** They return carry
  clear whatever happens and report completion in flag 240, so no fade
  call can fail the entry that holds the `GFX 0 4` ... `GFX 0 3`
  bracket and strand buffer mode open. If another module holds the
  palette when fn 40 is called, the fade is refused and flag 240 reads
  1 at once - nothing to wait for.

Two more palette rules live elsewhere: the hook's interlock (see
[The #int hook](#the-int-hook)) and `SVC_BUSY` bit 2 (see
[Services](#services)).

This is the sequence `externs/fade/README.md` documents; fn 42 needs
buffer mode open: without `GFX 0 4` there is no staged palette for it
to read, so the sequence above is the one to use.

## The EXTERN contract

`EXTERN p1 fn` calls your extern's entry point with the second parameter
as a dispatch selector, the way classic DAAD externs always worked. In a
Release build - the one your players run - three function codes are
reserved by the interpreter itself and never reach your code: 3 is
`XMESSAGE`, 4 is `XPART`, 7 is `XUNDONE`. Every other code your database
can compile - 0, 1, 2, 5, 6, 8-15, and everything from 16 upward -
forwards straight to your extern's entry point when one is loaded, and
behaves exactly as it did before externs existed (a harmless no-op) when
it is not. That is what makes it safe to ship a database written against
an XBN to a player who has none: nothing crashes, nothing errors, the
`EXTERN` calls that would have reached your code simply do nothing.

A DEBUG build additionally reserves function codes 6 and 8-14 for the
interpreter's own internal probes, so those codes do not reach your
extern there. Write your database against function codes outside
3-15 and it behaves identically in both builds; if you use 6 or 8-14,
expect that behaviour only in a Release build - test against Release
when you rely on it.

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
call beyond what it needs for its own bookkeeping - with ONE exception:
the carry flag on return is your extern's verdict on the entry that
called it (next section). Keep stack usage modest - your extern runs on
the interpreter's own stack, and a couple of hundred bytes of headroom
is a safe budget.

Unlike some classic DAAD interpreters, this one does not let an extern
consume extra bytes inline from the condact stream - there is no way to
read "the next byte after this EXTERN" the way some machines' externs
could. Pass extra data through flags instead: `LET` a value before the
`EXTERN` call, or build a lookup table in your XBN indexed by the
function code.

### Condition semantics

`EXTERN` is a condition as well as an action. When your entry point
returns with the carry flag CLEAR, the entry continues past the
`EXTERN` exactly as it always did. When it returns with the carry flag
SET, the calling entry FAILS: processing falls to the next matching
entry, the way a failed `AT` or `PRESENT` behaves. The done state is
treated the same way as for a failed built-in condition: the extern
itself does not count as an action performed, and an action that ran
earlier in the same table keeps its done stamp. Putting the `EXTERN`
guard FIRST in an entry, before the actions that depend on it, is still
the clearest shape.

Every path out of your extern must therefore return a DELIBERATE carry
state: `or a` before a `ret` clears it, `scf` sets it. A dispatcher that
does not recognise the function code returns with carry clear, so an
`EXTERN` meant for another module (or for nothing) never fails an entry
by accident:

    ext:
        ld a, c
        cp 20
        jp z, my_action
        cp 21
        jp z, my_condition
    .notmine:
        or a                ; not my fn: carry clear, the entry continues
        ret

    my_action:              ; an ACTION: always carry clear on the way out
        ...
        or a
        ret

    my_condition:           ; a CONDITION: carry set = "no", the entry fails
        ld a, (XBN_FLAGS + 100)
        cp 5
        jr c, .no
        or a
        ret
    .no:
        scf
        ret

Use it for anything a built-in condition would be used for: a guard
("is the hint book present?"), a predicate query ("is there an object
with this noun?"), or a chance test that behaves like `CHANCE`:

    > LOOK _   EXTERN  77 21    ; passes about 30% of the time, like CHANCE 30
               MES     3        ; "You notice something."
               DONE
    > LOOK _   MES     4        ; the fallthrough entry
               DONE

where fn 21 is four instructions - `call SVC_RANDOM` / `cp b` / `ccf` /
`ret` (B still holds the parameter because `SVC_RANDOM` preserves BC;
`cp` sets carry when the byte is below it, and `ccf` turns that into
the verdict: carry clear = pass): 77 of the 256 possible bytes pass,
about 30%, which is what `CHANCE 30` does with the same stream. Note
the inversion - `cp`'s carry sense is the opposite of the verdict's,
the commonest way an incidental carry leaks into a `ret`. Document, for
every function you publish, whether it is an action (always carry clear)
or a condition (what "no" means).

Three things never fail an entry, whatever your code does (nor do the
DEBUG build's probe codes 6 and 8-14, which never reach you there): an
`EXTERN` with no `GAME.XBN` loaded (still a pure no-op, so a database
written against an XBN stays shippable to a player who has none), the
reserved codes 3, 4 and 7 (the interpreter's own vectors), and `CALL`
(a pure action with no return contract).

### The result convention

Carry is the ONE failure channel, with one documented meaning per
function. Flags carry only values (a count, a result, a found object
number), inputs (parameters the game sets before the call) and async
state (a completion or expiry the game polls across turns - carry
speaks only at the moment of `RET`, so a fade's "done" lives in a flag).
Do not invent status enumerations: a failure reason the game needs to
distinguish belongs to a separate guard function that answers it as a
condition, checked once up front. The collection modules below follow
this convention to the letter and are the worked examples.

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
nothing meaningful. `CALL` ignores your carry flag - only `EXTERN`
carries a verdict.

## The #int hook

If your XBN's header names an interrupt entry point, the interpreter
calls it once every frame, at 50Hz, from inside its own frame interrupt.
This is real interrupt-context code, and the rules that come with that
are not optional:

- **Keep it short.** Well under one frame's worth of time. An overrun
  delays the next audio tick.
- **Never enable interrupts.** Do not execute `EI`.
- **Never `halt` inside the hook.** The frame interrupt's own source is
  masked while its handler runs, so a `halt` there waits for an edge
  that cannot come - and with a sampled effect playing, the sample
  interrupt would wake it after about 64 microseconds instead. Either
  way it is never a frame wait; gate on `SVC_FRAMES` from the
  foreground.
- **No DMA.** Do not use the zxnDMA - it contends with video and sample
  streaming DMA already in flight.
- **No file IO, and only the hook-safe services.** Four rows may be
  called from the hook: `SVC_VERSION`, `SVC_RANDOM`, `SVC_FRAMES` and
  `SVC_BUSY` - they touch resident memory and never page. Every other
  row (printing, files, `SVC_GETMSG`, `SVC_GETDATE`, `SVC_PALREAD`,
  `SVC_WINDOW`, `SVC_PAIR`) is foreground-only; see [Services](#services).
- **Never install your own interrupt handler.** The IM2 vector table is
  writable RAM, but your code only exists in the address space while
  its own bank is mapped - a self-installed vector is a guaranteed
  crash the moment your bank is unmapped again. The `#int` hook is the
  only legal interrupt-context entry point into your code.
- **Direct tilemap writes are fine.** Writing to the tilemap at `$6000`
  from inside the hook is legitimate and race-free: the interrupt
  handler never remaps that window on its own account. During a clip's
  open and prefill the hook still runs and bit 0 reads 1 (the tilemap
  is untouched then); from the moment the clip is armed until its
  teardown has restored the screen the hook does not run at all. Frames
  the hook was not invoked for are still visible through `SVC_FRAMES`,
  so a hook that measures elapsed time as a delta from that counter
  (the clock and timer examples) loses nothing; a hook that emits
  something per invocation (the ticker) simply pauses for the clip. A
  hook that must not write during a clip can still test bit 0; the
  interpreter no longer relies on it doing so.
- **Do not cycle and fade at once.** `SVC_BUSY` bit 3 says a colour
  cycle is armed. The fade example does not check it; the game stops
  the cycle (`GFX 0 12`) before `EXTERN 0 40` and restarts it after
  `EXTERN 0 43`.
- **Respect the runtime text width.** A game can switch between 80x32
  and 40x32 text with `GFX n 18`, which changes the tilemap row stride
  (160 bytes per row at 80 columns, 80 at 40). The width is not part of
  the frozen ABI, so an extern that writes the tilemap directly asks the
  hardware each time: `xbnmod.inc`'s `xbn_width` returns the current
  width in E (80 or 40), the row stride in D (160 or 80) and the
  bottom-row base in HL, from one read of NR $6B bit 6; it is hook-safe.
  It corrupts AF, BC, DE, HL. The ticker example calls it every frame
  while armed, so a `GFX n 18` switch mid-message just carries on at the
  new width.
- **Stay inside rows 4-27 for anything that must be visible on every
  display.** The tilemap's origin (in either width) sits 32 pixels
  above and left of the ULA origin, so rows 0-3 and 28-31 land in the
  border area.
  Real display chains (HDMI scalers, monitor overscan) often crop
  border pixels: content parked there can be invisible on hardware
  while an emulator window shows it. Rows 4-27 overlay the area every
  display shows; the ticker example writes row 27 for exactly this
  reason. If you want a border row, verify it on your own target
  display first.
- **Mind video playback.** Video decode is bound by how many CPU cycles
  it can spend per frame; heavy work in your hook while a clip is
  playing will visibly degrade it. You own both the hook and the
  decision to run one during a cutscene - the interpreter does not stop
  you.
- **Never count `halt` wakeups as frames.** `halt` resumes on ANY
  maskable interrupt, and the frame interrupt is not the only one
  running: sampled sound effects are fed by a per-sample interrupt at
  the WAV's sample rate - 15625 Hz for the interpreter's own effects -
  so with an effect playing, a `halt` returns after roughly 64
  microseconds, not 20 milliseconds, and a looped effect makes that
  permanent. A foreground wait that counts halts runs up to 312 times
  fast. A wait that needs frames gates on `SVC_FRAMES`: take a snapshot,
  `halt` as a wakeup only, and measure elapsed frames as the counter
  minus the snapshot (`or a` / `sbc hl, de`) - never as the number of
  times `halt` returned. The fade example's fn 43 and the clock and
  timer modules are the worked patterns. Any wait also needs a bound (a
  maximum number of frames) so a stalled counter cannot hang the game.
- **Palette writes from the hook go through the interlock.** If your
  hook programs the Layer 2 palette, acquire `xbnmod.inc`'s palette
  owner from the foreground call that starts the effect
  (`xbn_pal_acquire`, with the id its owner-byte comment assigns your
  module in A - claim the next free number there), test it in the hook
  before every burst (`xbn_pal_check` - skip the frame if another module
  holds it) and release it from the call or hook that finishes
  (`xbn_pal_release`). Two hooks writing the palette in the same frame
  corrupt entries; the interlock makes that impossible. The fade example
  is the worked pattern; a second palette module inherits it.

On entry, IX points at the flags base, exactly as it does for an
`EXTERN` call. Every other register is undefined, and the interpreter
preserves nothing across the call for you - do not rely on any register
holding a value from a previous frame.

The hook runs whether or not there is anything for it to do, every
frame, for as long as the game plays. Test a flag or a variable of your
own first and return immediately when there is nothing to do - the
ticker example's `int` hook is one load-and-test when idle, and that
idiom is worth copying directly.

## The line hook

A format 3 `GAME.XBN` can name a fourth entry point, called once for
every line the player submits, after it leaves the editor and before
the echo or the parse. Declare it with `xbn.inc`'s `XBN_HEADER3` macro
(or `xbnmod.inc`'s `XBN_BEGIN3` in a collection module) in place of the
format 2 version, passing `0` for either new hook you do not need - see
[XBN format](reference/xbn-format.md#header).

Entry: HL = the typed line (resident, writable, ASCIIZ, up to 127
characters), B = its length, IX = the flags base, exactly as for
`EXTERN`. The NUL is the truth of the line's length; B is a convenience
the interpreter recomputes before every module in a collection, so
trust the NUL over B if your own rewrite changed the length.

Return with a carry flag verdict: CLEAR continues with the line - your
own rewrite included, if you changed the bytes at HL - into the
ordinary echo and parse. SET consumes the line silently: the
interpreter re-prompts, nothing is parsed, the each-turn process does
not run, and the turn counter does not advance.

The hook is NOT called for a timeout exit, for an injected line
(`SVC_INJECT`), or for a `SAVE`/`LOAD` filename prompt.

A line hook rewrites the line IN PLACE (the bytes at HL) and returns its
carry verdict; it must never call `SVC_INJECT` - injecting from here
overwrites `inpLine` mid-parse and parks a line the next `PARSE 0`
consumes as a phantom empty input.

It runs in the foreground, so any service is fair game here - this is
where a module doing file IO belongs. The transcript module flushes to
the card from this hook, once per turn, before that turn's response.

## The output hook

A format 3 `GAME.XBN` can name a fifth entry point, called once for
every character the interpreter is about to print.

Entry: C = the character about to print (`$0D` for a newline), IX =
the flags base. There is no return contract - the hook only watches;
its carry flag on return is ignored.

What it sees: decoded message text, `PRINT` digits, object names
already substituted for `_`/`@`, `NEWLINE`, and the flag 49 reprint of
the typed line - the same bytes that land on the tilemap from ordinary
game text. What it never sees: the editor's own keystroke echo while
the player is typing, the `More...` prompt, the newlines the word
wrapper inserts to fit a window's width (so a recording taken this way
is width-independent), or the charset-shift bytes `$0E`/`$0F`, `$0B`
(`CLS`) or `$0C` - none of those reach the hook. An accent glyph
(16-31) arrives as its raw byte, with no shift context around it.

The hook must call NO service at all. `SVC_GETMSG` and `SVC_WINDOW`
share state with the print already in flight, and `SVC_PUTCHAR` or
`SVC_PUTS` would recurse straight back into the print path that is
calling you. It must preserve the alternate register set (AF', BC',
DE', HL') - the trampoline does not save it for you - and it should be
tiny: it runs once per character, on every character the game ever
prints.

### Hooks in a collection

A collection binary has exactly one lineEntry and one outEntry in its
header, whatever the number of modules built in - `xbnmod.inc` chains
them for you (`XBN_LINE_ENTER`/`XBN_LINE_CALL`/`XBN_LINE_END` for the
line hook, `XBN_OUT_CALL` for the output hook). The first module whose
line hook returns carry set ends the chain for that line; modules after
it are skipped. Every module in a collection still needs an `int`
entry, even if it is only a `ret` - the chain macros assume one.

## Services

The interpreter exposes twenty small routines through a fixed jump
table at a frozen address, `XBN_API` (`$BEC8`). `xbn.inc` binds a symbol
to each row, so you call them by name:

| # | Symbol | In | Out | From the hook |
|---|--------|----|-----|---------------|
| 0 | `SVC_VERSION` | - | A = API version (`3` on this release) | yes |
| 1 | `SVC_PUTCHAR` | A = character | - | no |
| 2 | `SVC_PUTS` | HL = ASCIIZ string (may live in your own bank) | - | no |
| 3 | `SVC_FOPEN` | IX = ASCIIZ filename, B = mode | A = handle, or CF set + A = error | no |
| 4 | `SVC_FREAD` | A = handle, IX = buffer, BC = length | BC = bytes read, or CF set + A = error | no |
| 5 | `SVC_FWRITE` | A = handle, IX = buffer, BC = length | BC = bytes written; CF set + A = error, on failure | no |
| 6 | `SVC_FSEEK` | A = handle, BCDE = offset | CF set + A = error, on failure | no |
| 7 | `SVC_FCLOSE` | A = handle | - | no |
| 8 | `SVC_RANDOM` | - | A = random byte (full range, not the 1-100 `CHANCE` scale) | yes |
| 9 | `SVC_GETMSG` | A = user message number | HL = buffer, BC = length (max 256, truncated); CF set + A = `$FF` when the number is out of range (the buffer is not written) | no |
| 10 | `SVC_FRAMES` | - | HL = the interpreter's free-running 50Hz frame counter, 16 bits, wrapping. Compare against a snapshot; never read it as absolute time | yes |
| 11 | `SVC_GETDATE` | - | CF clear: BC = MS-DOS packed date, DE = MS-DOS packed time, H = seconds, L = hundredths (`$FF` if the RTC has none). CF set = no RTC or invalid: BC = DE = 0 and HL is undefined - never read the seconds on that path | no |
| 12 | `SVC_BUSY` | - | A = busy bits: bit 0 a video clip is playing, bit 1 the SD card is busy, bit 2 the interpreter is inside its palette or reveal critical section, bit 3 a colour cycle (`GFX n 11`) is armed. Unassigned bits read 0. During a clip's open and prefill the hook still runs and bit 0 reads 1 (the tilemap is untouched then); from the moment the clip is armed until its teardown has restored the screen the hook does not run at all. A hook that must not write during a clip can still test bit 0; the interpreter no longer relies on it doing so. Bit 2 is only ever observable from the hook; bit 3 reads the same from either context. Bit 0 is kept for compatibility (see the hook rules for when it reads 1) | yes |
| 13 | `SVC_PALREAD` | IX = 512-byte buffer, A = bank select: 0 the bank the display shows, 1 the other bank (the staged palette while `GFX 0 4` buffer mode is open) | 256 entries of two bytes: RRRGGGBB, then a second byte masked to `%11000001` (bits 7-6 the priority field, bit 0 the blue LSB); IX ends at buffer+512 | no |
| 14 | `SVC_WINDOW` | A = window number 0-7 | A = the previously selected window, after selecting window A through the interpreter's own machinery; CF set and no change for A > 7. Selecting flushes the pending word of the window being left and may raise the More prompt there | no |
| 15 | `SVC_PAIR` | B = paper, C = ink, each a 0-255 colour as `INK`/`PAPER` take it | A = the tilemap attribute byte for that (paper, ink) pair, allocated by the interpreter's own pair allocator, so it behaves exactly as text printed in those colours (227 works). A pair only keeps its colours while some on-screen cell uses it: resolve it where you use it, never cache it across a period when your cells are off screen (a `GFX n 18` width switch blanks every cell). Call it BEFORE `SVC_GETMSG` when one function needs both, because the staging buffer dies at the next service call | no |
| 16 | `SVC_GETLINE` | - | HL = ASCIIZ line the player last typed (resident, read-only), BC = length. CF set = the prompt that just ran ended in a timeout or an empty `ENTER`: HL then holds whatever the recall buffer already held (the partial line after a timeout). CF clear covers a typed submit, an order taken after a conjunction, and an injected turn - HL is always the last line actually typed, never injected text. A `SAVE`/`LOAD` filename never reaches this buffer - the prompt stashes and restores the line around it | no |
| 17 | `SVC_GETPENDING` | - | HL = ASCIIZ orders after a conjunction not yet consumed (empty when none), BC = length | no |
| 18 | `SVC_INJECT` | HL = ASCIIZ text (your own bank is fine), A = options: bit 0 = echo it as typed | CF set + A = `$FF` on refusal (over 127 characters, or a line already parked); nothing is written on refusal | no |
| 19 | `SVC_VOCFIND` | HL = ASCIIZ word (any case, first five characters count) | D = word id, E = type, CF clear; CF set = not in the vocabulary | no |

Call a service exactly like any other subroutine - `call SVC_PUTCHAR`
and so on. Every row preserves your XBN bank's own mapping across the
call: whatever a service does internally, your code resumes exactly
where it left off, with its own memory still mapped underneath it.
Clobbers are listed in the
[format reference](reference/xbn-format.md#service-table); only the
registers a row's Out column names carry a result.

A few things worth knowing about specific rows:

- **`SVC_PUTCHAR` and `SVC_PUTS` print through the current DAAD window.**
  Colours, word wrapping and the `More...` prompt all behave exactly as
  they do for ordinary game text, because that is the same print path
  they use. `SVC_PUTS` flushes the word wrapper before returning, so a
  buffered final word is never left stranded on screen.
- **`SVC_RANDOM` returns a raw byte**, uniformly distributed 0-255,
  from the same stream `CHANCE` and `RANDOM` use - scale or mask it
  yourself. It is safe from the hook, but a hook draw consumes the
  shared stream at an unpredictable moment, so a game that must replay
  identically cannot draw from the hook. It preserves BC, DE and HL.
- **File services are thin wrappers over the same esxDOS machinery the
  interpreter itself uses** for save games and asset loading. `mode` for
  `SVC_FOPEN` is the raw esxDOS open mode byte; the error convention
  throughout is esxDOS style - carry flag set, A holds the error code.
  Like the underlying wrappers, every file service may clobber AF, BC,
  DE, HL, IX and IY; only the columns the table above lists are
  meaningful on return.
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
  A = `$FF`, and the buffer is not written.
- **`SVC_FRAMES` is the frame clock.** HL is a 16-bit counter the
  frame interrupt increments; it wraps, so subtract a snapshot
  (`or a` / `sbc hl, de`) rather than reading it as a time. Safe from
  the hook. Frames the hook missed (a long draw, a video clip) are
  still counted, which is why the clock and timer modules keep time
  from its deltas instead of counting their own invocations.
- **`SVC_GETDATE` reads the real-time clock**, when the Next has one:
  carry clear with the MS-DOS packed date in BC (year-1980 in bits
  15-9, month in 8-5, day in 4-0), the packed time in DE (hour 15-11,
  minute 10-5, two-second units 4-0), seconds in H. Carry set means no
  RTC or an invalid reading: BC and DE are zero and HL is undefined,
  so never read the seconds on that path. Foreground only. The
  realtime module wraps it.
- **`SVC_BUSY` tells the hook what the interpreter is in the middle
  of.** Bit 0 a video clip is playing, bit 1 the SD card is busy, bit 2
  the interpreter is programming a palette or revealing a buffered
  picture, bit 3 a colour cycle (`GFX n 11`) is armed. Bit 0 is kept
  for compatibility: the hook runs (and can see it set) during a clip's
  open and prefill, then is suspended from the clip's arm point to its
  teardown. Bit 2 is only ever observable from the hook; bit 3 reads
  the same from either context.
- **`SVC_PALREAD` copies a Layer 2 palette bank into your buffer**, 256
  two-byte entries, exactly as the hardware holds them. A = 0 reads the
  bank the display is showing; A = 1 reads the other bank, which is
  where `DISPLAY` stages a picture's palette while buffer mode
  (`GFX 0 4`) is open - the fade module reads the incoming picture's
  colours this way before revealing it. IX ends at buffer+512.
  Foreground only.
- **`SVC_WINDOW` switches the current DAAD window and returns the one
  that was current**, so a printing routine can bracket its own output:
  select the target, print, re-select the returned window. Two effects
  an author must know: selecting a window flushes the pending word of
  the window you are leaving (a `MES "Score "` issued just before lands
  in the game window, not the target) and can raise the More prompt
  THERE; and once you print into the target, an exact line fill wraps
  and can raise More in the target, so size a status window for what it
  holds. Window geometry (`WINAT`, `WINSIZE`, colours) stays
  yours, set in DSF. Foreground only. The toolkit's fn 84 is the worked
  use.
- **`SVC_PAIR` is API version 3.** It resolves a (paper, ink) pair to a
  tilemap attribute the same way the interpreter's own print path does,
  so an extern's own screen writes match `INK`/`PAPER` text exactly. The
  ticker module's arm call shows the version-gated use.
- **`SVC_FWRITE` reports what it actually wrote.** BC on return is the
  number of bytes written - documented from API version 3, though the
  row always returned it. A short count with the carry flag still
  clear is esxDOS's seek-then-extend hazard: the write landed short of
  what you asked for without the call failing outright. Treat it as a
  failure exactly as you would a set carry flag.
- **`SVC_GETLINE` and `SVC_GETPENDING` read the player's input.**
  `SVC_GETLINE` returns the line the player actually typed - read-only,
  in the interpreter's own recall buffer - and its carry flag tells you
  whether the prompt that just ran ended cleanly: it is SET only when
  that prompt ended in a timeout or an empty `ENTER`, and HL then holds
  whatever the recall buffer already held (the partial line after a
  timeout). It is CLEAR for a typed submit, for an order taken after a
  conjunction, and for an injected turn - HL is always the last line
  the player actually typed, the injected text is never in this buffer.
  A `SAVE`/`LOAD` filename prompt never reaches this buffer either: it
  stashes the typed line and restores it afterwards, so an extern
  reading `SVC_GETLINE` after a `SAVE` earlier in the same turn still
  gets the player's actual command - the reassurance a name-entry or
  password prompt needs. `SVC_GETPENDING` returns whatever a
  conjunction ("and", "then") left unconsumed - `LOOK AND GET LAMP`
  leaves `GET LAMP` pending, with the leading blanks the parser left
  where it blanked the conjunction word still in the text, so folding
  this into an injected line picks up harmless extra spaces. Both are
  foreground only, resident memory, no paging.
- **`SVC_INJECT` queues a line for the very next `PARSE 0`**, bypassing
  the prompt entirely - your own bank is a fine source for the text,
  and option bit 0 echoes it as if the player had typed it. It
  REPLACES any pending order already queued from a conjunction; read
  `SVC_GETPENDING` first if you need to keep it. It refuses (carry
  set, A = `$FF`, nothing written) a line over 127 characters or a
  second injection while one is still parked. A rewriter called from a
  `PARSE` entry's own remainder must always inject something - the
  original line when nothing else matched - or the game's next
  `PARSE 0` silently prompts again with no visible cause. The line hook
  is different: it never calls `SVC_INJECT` at all, it rewrites the
  line in place instead. Never call it between a `PARSE 0` and the
  `PARSE 1` that reads the same order's quoted section: it parks its
  text over the buffer `PARSE 1` reads from and clobbers the quote.
- **`SVC_VOCFIND` resolves a word against your database's own
  vocabulary**, the same lookup the parser itself uses - any case, only
  the first five characters significant. HL points at ONE word: a
  space or other punctuation counts as an ordinary character toward
  the five, so pass a single word, not a phrase. Foreground only, and
  more strictly than most rows marked that way: never call it from the
  output hook. The output hook is not the `#int` hook, but the lookup
  reuses shared resident state that a print already in flight is also
  using.

### Versioning

`SVC_VERSION` returns `3` on this release. The service table is
append-only and its address is frozen: existing rows never move and
never change signature, so code written against an older `xbn.inc`
keeps calling the same rows on every later NextDAAD release. What CAN
change between format versions is the file header, and it did at
format 2: a binary assembled against an older `xbn.inc` is reassembled
against the current one to pick up the new
[header](reference/xbn-format.md#header). New services arrive as new
rows at the end with a version bump. An extern that needs a row its
`xbn.inc` did not ship with checks the version first and fails
gracefully instead of jumping into whatever used to live there - the
hints module's preflight is the idiom:

    MIN_API equ 2
    preflight:
        call SVC_VERSION
        cp MIN_API
        jr nc, .ok
        scf                 ; older interpreter: the condition fails
        ret
    .ok:
        ...

The format version (the header's byte 3) stays `2` unless your XBN
declares a line or output hook, which needs format `3` (see
[XBN format](reference/xbn-format.md#header)) - a stricter cliff than
the API version: a format 3 header needs this release's loader, and an
interpreter that predates it rejects the header outright and the game
plays with externs off, where an old `xbn.inc` simply never calls the
rows it does not know about. Rows 15 to 19 - `SVC_PAIR` through
`SVC_VOCFIND` - are all API version 3, whichever header format you use;
the API version is `3` since `SVC_PAIR` was appended. They are separate
contracts: the loader enforces the format version, your code checks the
API version.

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
  your own. The object count is at `XBN_NUMOBJ` (`$A900`, one byte,
  frozen): read the count with `ld a, (XBN_NUMOBJ)` and walk objects
  `0` to `(XBN_NUMOBJ) - 1` - the byte's value, never a fixed 256,
  because entries past the count are stale. The two extended-attribute
  bytes are stored in flag order - offset 3 holds attribute bits 0-7
  and offset 2 holds bits 8-15 - so attribute `n` below 8 is bit `n` of
  `(+3)`. The toolkit's object queries (fns 78-81) are the worked
  readers.

## Save and load

The extern bank itself is never part of a save game. `SAVE`, `LOAD`,
`RAMSAVE` and `RAMLOAD` persist flags and object state exactly as they
always did - nothing about your XBN's own code or data changes because
of them. Practically, that means:

- **Anything that must agree with the flags after a `LOAD` belongs in
  the state area or in a flag**, not in ordinary bank memory. A `LOAD`
  restores flags to whatever they held at save time, and restores the
  [extern state area](#the-extern-state-area) the same way; it does not
  touch the rest of your bank at all, so a value kept only there is
  left exactly as it was before the load - stale, not restored.
- **Bank-resident state outside the state area survives within a
  session**: across `EXTERN`/`CALL` invocations, across part switches,
  and across `RESTART`. It is only a `LOAD` (or a `RAMLOAD`) that
  leaves it unsynchronised with the flags the player just restored -
  the state area is the tool for the part of that state that needs to
  survive a `LOAD` too.
- **There is no dedicated init entry.** Initialise your extern's own
  state from an ordinary `EXTERN` call in your startup process, the way
  classic DAAD games initialised externs from `PRO 6`.

## The extern state area

128 bytes at `XBN_STATE` (`$BF80`, a frozen address) are the one piece
of your extern's own memory that travels with the game's save data.
`SAVE` writes it, `LOAD` restores it, `RAMSAVE` and `RAMLOAD` carry it
the same way - `RAMLOAD n` restores it whatever `n` is. It is
zeroed once, at boot: `RESTART` and a part switch leave it exactly as
your extern last set it.

A save file made before this area existed loads with it zeroed. A save
file that carries it loads fine on an interpreter that predates the
area - the extra bytes are simply never read.

Membership rule: put here only state that must agree with the flags
after a `LOAD` - the same test the [Save and load](#save-and-load)
rule above applies to a flag. Session configuration - whether a module
is armed, a recorder's own bookkeeping, colours chosen this session -
stays ordinary bank memory; only what the player would notice was
wrong after loading an old save belongs in the state area.

Claim your own offsets through `xbnmod.inc`'s `XBN_STATE_FREE` chain,
the same discipline as the `CALL` slot table: bump it past whatever you
claim so the next module's claim does not collide with yours. The
toolkit claims the first ten bytes (the picker's pool size and used
bitmap, the print target window) - fn 76's picker and fn 84's print
target are now restored by `LOAD` and `RAMLOAD`, where they used to go
stale.

One edge case worth knowing: a cross-part `LOAD` whose target part
fails to load leaves the state area restored to the save's values while
the flags are not.

## The extern collection

The kit ships a collection of ready-made externs under `externs\`, one
folder each: the assembly source, a prebuilt `GAME.XBN` you can copy
straight to the card, a `README.md` with the DSF lines that drive it,
and a rebuild script. The ticker and fade worked examples above are two
of them; the other six are libraries to use as they come, no assembler
needed.

| Extern | What it does | fn codes | Flags used |
|--------|--------------|----------|------------|
| `ticker/` | Types or scrolls a database message in a field you place, size and colour - typewriter, marquee once or looping marquee | 30 arm, 31 stop (p = 1 clears), 32 row, 33 column, 34 width, 35 ink, 36 paper, 37 mode, 38 speed | - |
| `fade/` | Fades the Layer 2 picture to any RRRGGGBB colour and back - fade to black for a scene change, change the picture, fade up again. Transparent regions stay transparent; a completed fade-in restores the palette bit for bit | 40 fade out, 41 fade in, 42 re-snapshot after a picture change, 43 wait for the fade | 240 done, 241 speed |
| `hints/` | Prints hint text served from an SD card file (`GAME.HNT`), so a game can ship a large hint book without spending DAAD message slots or interpreter RAM | 50 print hint, 51 level count, 52 preflight, 53 clear progress | 242 level override, 243 level count |
| `clock/` | An in-game clock advanced from the frame hook, with hour carry and an author-driven advance for sleeping or travelling | 60 arm and start, 61 stop, 62 advance p minutes | 224 hours, 225 minutes, 226 running, 227/228 rate, 244 days |
| `timer/` | Three independent countdown timers, counting real seconds or in-game minutes, that expire into a flag your process table can test | 63 arm, 64 stop all three, 65 arm slot p as an in-game-minute deadline | 229-234 remaining (3 pairs), 235-237 state; an armed in-game-minute slot also READS the clock's 224, 225 and 244 |
| `realtime/` | Reads the Next's real-time clock: date and time fields for the game to print or test, and day stamps kept in `GAME.HST` beside the database so a game can tell how long it has been since the last visit | 66 refresh, 67 field, 68 stamp, 69 days since | 238 result, 239 available |
| `toolkit/` | Decimal printing, 16-bit flag-pair arithmetic, object queries, a random-without-repeat picker and time formatting. No hook - every function runs to completion inside the EXTERN that calls it; fns 76 and 84 keep their state in the extern state area, restored by LOAD | 70-84: 70 print flag as decimal, 71 print pair as decimal, 72-75 16-bit arithmetic, 76/77 picker, 78-81 object queries, 82 HH:MM, 83 MM:SS, 84 print target window | 248 width, 249 operand, 250 fn 79's high byte, 251 result |
| `transcript/` | Records every typed line, and optionally everything printed, to `TRANS.TXT` beside the database - a walkthrough recorder, or a bug report that writes itself. Needs a v0.10.1 interpreter (format 3 header, line and output hooks) - an older interpreter loads the game with the module off | 90 start recording (mode bitmask), 91 stop, 92 condition, 93 write message n as a label line, 94 restrict to window w | - |

Function codes and flags are disjoint across the whole collection, so
any subset coexists in one binary. Flags 224-251 are the collection's
reserved band: a game using any collection module should treat that
range as spoken for. Function codes 66-69 (realtime), 76-81 and 84
(toolkit's object queries, picker and print target) joined that
allocation in an earlier release; function codes 90-94 (transcript,
which claims no flags) joined it in this one.

### One binary, any subset

A game loads ONE `GAME.XBN`, and you never merge sources by hand:

- `externs\all\GAME.XBN` ships every module in one prebuilt binary.
  Copy it beside `GAME.DDB` and use whichever functions you want.
- `EXTERNS.BAT ticker fade` from the kit root builds a binary holding
  only the modules you name (this route needs sjasmplus - see
  `externs\README.md` for where it looks).

An unused module costs nothing at run time. This is the collection's
dormancy rule: every module stays inert until the game invokes it - an
arming call for the modules that have one (`EXTERN 0 60` for the clock,
`EXTERN 0 63` for the timer, `EXTERN n 30` for the ticker), or simply
never being called for the rest. Until then a module's share of the
frame hook is a single load-and-test and its flags are untouched, so a
game shipping `all/GAME.XBN` and using only the fade pays for only the
fade. Arming is bank state: it survives `RESTART`, a part switch and a
`LOAD`, but not a fresh boot, so arming calls belong in your start
process, the way classic DAAD games initialised externs from `PRO 6`.

Two toolkit functions used to go stale across a `LOAD`: the picker
(fn 76) and the print target (fn 84). Both now keep their state in the
[extern state area](#the-extern-state-area), so a `LOAD` or a
`RAMLOAD` restores the picker's pool size and used mask and the print
target's window exactly as they stood when the game was saved - no
re-arming needed on that path. The start process still covers a fresh
boot, which the state area's own zero-at-boot rule does not.

`CALL` targets in collection binaries are SLOTS in a fixed jump table
at `$C00E` - slot n at `$C00E + 3n`, so slot 0 is `CALL 14 192` -
never routine addresses, which move whenever any module is edited. An
unowned slot jumps to a bare `RET` and does nothing.

Collection modules get that table from `xbnmod.inc`'s `XBN_BEGIN` (or
`XBN_BEGIN3`, its format 3 twin, for a module with a line or output
hook), used in place of `XBN_HEADER`/`XBN_HEADER3`; `CONTRIBUTING.md`
at the repository root documents the module shape.

### hints - a hint book on the card

Author `HINTS.TXT` beside your game source; `BUILD.BAT` packs it into
`RELEASE\GAME.HNT` (up to 256 topics, 255 levels per topic, 64KB of
text - see [Limits](reference/limits.md)). The extern prints a topic's
next unread hint and remembers per-topic progress in `GAME.HPR` on the
card, costing you no flags and surviving `LOAD` and `RESTART`:

```
EXTERN 0 52    ; CONDITION: fails the entry when the hint book is
               ; missing or unreadable - check it once at startup
EXTERN 3 50    ; CONDITION: prints topic 3's next unread hint and
               ; advances; fails when there is no further hint to give
EXTERN 3 51    ; ACTION: level count for topic 3 into flag 243
EXTERN 0 53    ; CONDITION: resets every topic's progress; fails if
               ; the reset did not take
```

Flag 242 nonzero pins every topic to that level (1 = the first hint)
instead of advancing. There are no status codes: each function's carry
is its one verdict, and flag 243 is only fn 51's count. A hint that
printed but whose progress could not be saved still counts as success -
the player got the hint; it may print again next time. The module's
README has the authoring rules for hint text.

### clock and timer - in-game time and deadlines

The clock keeps hours, minutes and days in flags 224/225/244, advanced
by the frame hook at flag 227/228's rate (frames per in-game minute:
50 = one in-game minute per real second, 3000 = true 1:1). Both
modules keep time from `SVC_FRAMES` deltas, so frames the hook missed
during a long draw or a video clip are still counted. Setting the
time is a plain `LET`; an event at 14:37 is an ordinary process entry:

```
LET 227 50     ; rate, then arm from your start process:
EXTERN 0 60    ; arm and start (first call only; no-op once armed)
...
> _  _    EQ  224 14
          EQ  225 37
          ; the guard returns
```

The timer module runs three independent countdowns that expire into
state flags (235-237: 0 idle, 1 real seconds, 2 in-game minutes,
3 expired), each with a 16-bit pair (229/230, 231/232, 233/234, low
byte first). A real-seconds timer is armed with plain `LET`s; an
in-game-minute deadline needs `EXTERN d 65` to convert a duration into
a deadline against the clock. `EXTERN d 65` refuses a duration of 32768
or more - it fails the entry (carry set) and, because it quiesces the
slot before checking, also stops any countdown that slot was running.
Each module's README covers the arithmetic and the save/load
behaviour.

### realtime - the wall clock and day stamps

The realtime module reads the Next's own clock, when the machine has
one. It takes the date and time as a single snapshot and then serves
that snapshot a field at a time into flag 238, so an ordinary DSF
condition can test the hour, the weekday or the month - and the hour
and the minute you test in the same turn cannot come from either side
of a tick. There is no frame hook and no arming call:

```
EXTERN 0 66    ; CONDITION: refresh the snapshot from the clock; fails
               ; the entry when there is no RTC. Flag 239 = 1 when one
               ; answered, 0 when none did
EXTERN 2 67    ; ACTION: field 2, the hour, into flag 238. The fields
               ; are 0 second, 1 minute, 2 hour, 3 day of the month,
               ; 4 month, 5 year as a 2000-2099 offset (2026 reads 26),
               ; 6 weekday with 0 = Sunday
EXTERN 0 68    ; CONDITION: stamp today into GAME.HST beside the
               ; database; fails with no clock, or if the write failed
EXTERN 0 69    ; CONDITION: days since that stamp into flag 238; fails
               ; when there is no stamp yet, reads 0 if the clock has
               ; gone backwards, and caps at 255
```

fns 68 and 69 read the clock for themselves, so neither needs an
`EXTERN 0 66` first; the snapshot serves fn 67 only.

A machine with no working clock is the normal case to write for, not an
error: `EXTERN 0 66` fails its entry and sets flag 239 = 0, and
`EXTERN f 67` then writes flag 238 = 0 for every field. fns 68 and 69
fail the same way. Hang the date-dependent path off a successful fn 66,
or off a test of flag 239, and the game plays normally without one.

A flag changing while the player sits at the prompt is invisible until
a turn runs, so a clock event on its own only fires when the player
happens to type. DAAD's input timeout is the other half of real time:
flag 48 arms it, in seconds, and flag 49 bit 7 reports that it fired.
With flag 48 armed, a turn happens on a timer and your process table
runs - and your clock events fire - while the player is still
thinking. Without it, "real time" quietly is not.

The module's README has the full field table, the invalid-reading case
and what fn 67 writes for a field above 6.

### toolkit - printing and 16-bit arithmetic

Fifteen functions with no frame hook of their own: each one runs to
completion inside the `EXTERN` that calls it. Most take the `EXTERN`
parameter as a FLAG NUMBER and read or write through that flag. The
exceptions take it as a plain value: the object queries (fns 78-81),
the picker's pool size (fn 76) and the print target's window number
(fn 84).

```
LET 248 5          ; field width 5, space-padded (133 = zero-padded)
EXTERN 100 71      ; print the 16-bit pair at flags 100/101
EXTERN 224 82      ; print the clock's flags 224/225 as HH:MM
LET 249 102
EXTERN 100 74      ; compare pair [100] with pair [102] into flag 251
```

Fns 70/71 print a byte and a 16-bit pair as decimal, padded to flag
248's field width; fns 72/73/75 add and subtract 16-bit pairs, leaving
1 in flag 251 when the result wrapped and 0 when it did not; fn 74
compares two pairs and writes 0 less, 1 equal, 2 greater into flag 251,
changing neither pair; fns 82/83 format HH:MM and MM:SS. All of these
are ACTIONS - an overflow reports in a flag rather than failing the
entry, because wrapping and carrying on is often what a game wants.
Four of the printing functions are also reachable through `CALL` slots
0-3 with the flag number in flag 249.

Printing goes through the current DAAD window by default. `EXTERN 2 84`
sets a print target once, and from then on fns 70, 71, 82, 83 and the
four `CALL` slots bracket their own output - select the target, print,
restore what was current - so you write no `WINDOW` bracket around them
and never leave a bare number buffered. A DAAD `MES` is unaffected: it
still prints wherever the game's own `WINDOW` points.

Entering the target flushes the CURRENT window's pending word first,
the same as any window switch (see [`SVC_WINDOW`](#services)), so a
`MES "Score "` issued just before an `EXTERN 100 71` puts "Score" in
the game window and the number in the status window rather than side by
side. Clear the target with `EXTERN 0 84` before a print that mixes
`MES` text and a number inline. The target positions and clears
nothing, so its prints APPEND after whatever was painted there last,
until the status process repaints with its own `WINDOW 2` and `CLS`.

The other six read the interpreter's live object table, or the module's
own picker, and all but one are CONDITIONS - they fail the entry when
there is nothing to report, exactly like a failed `AT`:

```
EXTERN loc 78    ; CONDITION: count the objects at location loc into
                 ; flag 251; fails when there are none
EXTERN noun 80   ; CONDITION: lowest-numbered object with that noun
                 ; into flag 251; fails when nothing matches
EXTERN bit 81    ; CONDITION: count objects with extended attribute
                 ; bit set, into flag 251; fails at none, and a bit
                 ; above 15 is refused the same way
EXTERN 0 79      ; ACTION: total carried and worn weight as a 16-bit
                 ; pair - LOW byte in flag 251, HIGH byte in flag 250
EXTERN 6 76      ; CONDITION: arm the picker with a pool of 6; refuses
                 ; a pool of 0, or above 64, and leaves the old one
EXTERN 0 77      ; CONDITION: pick an index not yet used into flag
                 ; 251; fails once the pool is exhausted
```

Fn 80's failure is the discriminator, not its flag: object 0 is a
legitimate answer, so a bare `EQ 251 0` cannot tell "found object 0"
from "found nothing". Fn 79's pair is HIGH-then-low across 250/251,
which is not fn 71's low-first order, so copy it into a pair of your
own before printing it. An exhausted picker does not re-arm itself: a
second `EXTERN 6 76` starts the cycle again, one visible line rather
than a silent reset. The module's README has the full worked status
line and the container rules fn 79 follows.

A number printed as the last thing in an entry stays in the word
wrapper's buffer until a space, a newline, a window switch or a full
window width flushes it - which is what the print target's own bracket
does for you.

## Contributing your extern

Written an extern other games could use? The collection above takes
community submissions - each ships as source plus a
prebuilt binary, so authors who cannot assemble can still use yours.
The submission requirements, the rules your code must obey and the
automated audit that checks them are described in `CONTRIBUTING.md` at
the root of the NextDAAD repository:
https://github.com/absent42/NextDAAD

The kit also ships an agent skill for writing externs -
`.agent\skills\xbn-extern-authoring\` at the kit root - that any AI
coding assistant can load.
