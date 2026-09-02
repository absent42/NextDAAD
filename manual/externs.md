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
one character per frame along the bottom row of the tilemap - in either
text width, probing NR $6B bit 6 each character so a `GFX n 18` switch
mid-message just carries on at the new width. It ships
with a prebuilt `GAME.XBN` beside the source, so you can try it on a
card without assembling anything. Its own `README.md` covers how to
build it and wire it into a DSF; the source comments walk through
every decision, including the one mistake it is built to guard you
away from - see [SVC_GETMSG's staging semantics](#services) below. It
is the same code this chapter's examples are drawn from.

### The fade example

The kit's second worked example, `externs/fade`, fades the Layer 2
picture to any RRRGGGBB colour and back for narrative beats. Beyond the
ticker example's XBN mechanics, it demonstrates reading hardware state
back (the palette snapshot), the register-select save/restore bracket
around shared indexed registers, and foreground precompute feeding a
cheap interrupt hook. It ships with a prebuilt `GAME.XBN` beside the
source, so you can try it on a card without assembling anything, and
its own `README.md` covers building it and wiring it into a DSF.

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
EXTERN 0 42   ; snapshot the hidden palette, rebuild the fade tables,
              ; solid it into both palette banks
GFX 0 2       ; reveal: flip the surface; every palette is solid
GFX 0 3       ; close buffer mode; drawing targets the screen again
EXTERN 0 41   ; fade up to the new picture
EXTERN 0 43
```

Two rules keep this sequence honest:

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

This is the same sequence documented in `externs/fade/fade.asm`'s own
header, kept in step with it here.

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
entry, the way a failed `AT` or `PRESENT` behaves - and the entry's done
state is cleared, so `ISDONE` afterwards reads not-done even if an
action earlier in the same entry had already run. Put the `EXTERN`
guard FIRST in an entry, before the actions that depend on it, and that
edge never shows.

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
- **No DMA.** Do not use the zxnDMA - it contends with video and sample
  streaming DMA already in flight.
- **No file IO, and only the hook-safe services.** Four rows may be
  called from the hook: `SVC_VERSION`, `SVC_RANDOM`, `SVC_FRAMES` and
  `SVC_BUSY` - they read resident memory and never page. Every other
  row (printing, files, `SVC_GETMSG`, `SVC_GETDATE`, `SVC_PALREAD`,
  `SVC_WINDOW`) is foreground-only; see [Services](#services).
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
  buffer instead and corrupts the clip's sound. Call `SVC_BUSY` at the
  top of the hook and skip the frame while bit 0 (a clip is playing) is
  set - emit nothing and advance nothing, so the message resumes where
  it stopped. The ticker example does exactly this.
- **Respect the runtime text width.** A game can switch between 80x32
  and 40x32 text with `GFX n 18`, which changes the tilemap row stride
  (160 bytes per row at 80 columns, 80 at 40). The width is not part of
  the frozen ABI, so an extern that writes the tilemap directly asks the
  hardware each time: `xbnmod.inc`'s `xbn_width` returns the current
  width in E (80 or 40), the row stride in D (160 or 80) and the
  bottom-row base in HL, from one read of NR $6B bit 6; it is hook-safe.
  The ticker example calls it per character, so a `GFX n 18` switch
  mid-message just carries on at the new width.
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

## Services

The interpreter exposes fifteen small routines through a fixed jump
table at a frozen address, `XBN_API` (`$BEC8`). `xbn.inc` binds a symbol
to each row, so you call them by name:

| # | Symbol | In | Out | From the hook |
|---|--------|----|-----|---------------|
| 0 | `SVC_VERSION` | - | A = API version (`2` on this release) | yes |
| 1 | `SVC_PUTCHAR` | A = character | - | no |
| 2 | `SVC_PUTS` | HL = ASCIIZ string (may live in your own bank) | - | no |
| 3 | `SVC_FOPEN` | IX = ASCIIZ filename, B = mode | A = handle, or CF set + A = error | no |
| 4 | `SVC_FREAD` | A = handle, IX = buffer, BC = length | BC = bytes read, or CF set + A = error | no |
| 5 | `SVC_FWRITE` | A = handle, IX = buffer, BC = length | CF set + A = error, on failure | no |
| 6 | `SVC_FSEEK` | A = handle, BCDE = offset | CF set + A = error, on failure | no |
| 7 | `SVC_FCLOSE` | A = handle | - | no |
| 8 | `SVC_RANDOM` | - | A = random byte (full range, not the 1-100 `CHANCE` scale) | yes |
| 9 | `SVC_GETMSG` | A = user message number | HL = buffer, BC = length (max 256, truncated); CF set + A = `$FF` when the number is out of range (the buffer is not written) | no |
| 10 | `SVC_FRAMES` | - | HL = the interpreter's free-running 50Hz frame counter, 16 bits, wrapping. Compare against a snapshot; never read it as absolute time | yes |
| 11 | `SVC_GETDATE` | - | CF clear: BC = MS-DOS packed date, DE = MS-DOS packed time, H = seconds, L = hundredths (`$FF` if the RTC has none). CF set = no RTC or invalid: BC = DE = 0 and HL is undefined - never read the seconds on that path | no |
| 12 | `SVC_BUSY` | - | A = busy bits: bit 0 a video clip is playing, bit 1 the SD card is busy, bit 2 the interpreter is inside its palette or reveal critical section. Unassigned bits read 0. Bits 0 and 2 are only ever observable from the hook | yes |
| 13 | `SVC_PALREAD` | IX = 512-byte buffer, A = bank select: 0 the bank the display shows, 1 the other bank (the staged palette while `GFX 0 4` buffer mode is open) | 256 entries of two bytes: RRRGGGBB, then a second byte masked to `%11000001` (bits 7-6 the priority field, bit 0 the blue LSB); IX ends at buffer+512 | no |
| 14 | `SVC_WINDOW` | A = window number 0-7 | selects that window through the interpreter's own machinery and returns A = the previously selected window; CF set and no change for A > 7. Selecting flushes the pending word of the window being left and may raise the More prompt there | no |

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
  of.** Bit 0 a video clip is playing (the tilemap window is the clip's
  audio feed - do not write it), bit 1 the SD card is busy, bit 2 the
  interpreter is programming a palette or revealing a buffered picture.
  Bits 0 and 2 are only ever set while a hook could observe them; from
  the foreground they read 0.
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

### Versioning

`SVC_VERSION` returns `2` on this release. The service table is
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

The format version (the header's byte 3, `2`) and the API version are
the same number on this release but are separate contracts: the loader
enforces the first, your code checks the second.

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

## The extern collection

The kit ships a collection of ready-made externs under `externs\`, one
folder each: the assembly source, a prebuilt `GAME.XBN` you can copy
straight to the card, a `README.md` with the DSF lines that drive it,
and a rebuild script. The ticker and fade worked examples above are two
of them; the other four are libraries to use as they come, no assembler
needed.

| Module | Does | fn codes | Flags |
|--------|------|----------|-------|
| `ticker` | Types a database message along the bottom row, one character per frame | 30 arm, 31 disarm | - |
| `fade` | Fades the Layer 2 picture to any RRRGGGBB colour and back | 40 out, 41 in, 42 re-snapshot, 43 wait | 240 done, 241 speed |
| `hints` | Prints hint text served from an SD card file | 50 print, 51 count, 52 preflight, 53 reset | 242 level override, 243 status/count |
| `clock` | An in-game clock advanced from the frame hook | 60 arm and start, 61 stop, 62 advance | 224 hours, 225 minutes, 226 running, 227/228 rate, 244 days |
| `timer` | Three countdown timers that expire into flags | 63 arm, 64 stop all, 65 minute deadline | 229-234 pairs, 235-237 states |
| `toolkit` | Decimal printing, 16-bit flag-pair arithmetic, time formats | 70/71 print, 72-75 arithmetic, 82 HH:MM, 83 MM:SS, 76-81 reserved | 248 width, 249 operand, 250 reserved, 251 result |

Function codes and flags are disjoint across the whole collection, so
any subset coexists in one binary. Flags 224-251 are the collection's
reserved band: a game using any collection module should treat that
range as spoken for.

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

`CALL` targets in collection binaries are SLOTS in a fixed jump table
at `$C00A` - slot n at `$C00A + 3n`, so slot 0 is `CALL 10 192` -
never routine addresses, which move whenever any module is edited. An
unowned slot jumps to a bare `RET` and does nothing.

Collection modules get that table from `xbnmod.inc`'s `XBN_BEGIN`, used
in place of `XBN_HEADER`; `CONTRIBUTING.md` at the repository root
documents the module shape.

### hints - a hint book on the card

Author `HINTS.TXT` beside your game source; `BUILD.BAT` packs it into
`RELEASE\GAME.HNT` (up to 256 topics, 255 levels per topic, 64KB of
text - see [Limits](reference/limits.md)). The extern prints a topic's
next unread hint and remembers per-topic progress in `GAME.HPR` on the
card, costing you no flags and surviving `LOAD` and `RESTART`:

```
EXTERN 0 52    ; preflight once at startup: flag 243 = 0 means the
               ; hint file is present and readable
EXTERN 3 50    ; print topic 3's next unread hint and advance it
EXTERN 3 51    ; level count for topic 3 into flag 243
EXTERN 0 53    ; reset every topic's progress
```

Flag 242 nonzero pins every topic to that level (1 = the first hint)
instead of advancing; flag 243 carries a status code after fns 50/52/53
and the count after fn 51. The module's README documents the status
codes and the authoring rules for hint text.

### clock and timer - in-game time and deadlines

The clock keeps hours, minutes and days in flags 224/225/244, advanced
by the frame hook at flag 227/228's rate (frames per in-game minute:
50 = one in-game minute per real second, 3000 = true 1:1). Setting the
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
a deadline against the clock. Each module's README covers the
arithmetic, the 32767-minute ceiling and the save/load behaviour.

### Real-time events and flag 48

A flag changing while the player sits at the prompt is invisible until
a turn runs, so a clock event on its own only fires when the player
happens to type. DAAD's input timeout is the other half of real time:
flag 48 arms it, in seconds, and flag 49 bit 7 reports that it fired.
With flag 48 armed, a turn happens on a timer and your process table
runs - and your clock events fire - while the player is still
thinking. Without it, "real time" quietly is not.

### toolkit - printing and 16-bit arithmetic

Every toolkit function takes its `EXTERN` parameter as a FLAG NUMBER
and reads or writes through that flag. Printing goes through the
current DAAD window, so a status line is the author's own `WINDOW`
bracket around toolkit calls:

```
LET 248 5          ; field width 5, space-padded (133 = zero-padded)
EXTERN 100 71      ; print the 16-bit pair at flags 100/101
EXTERN 224 82      ; print the clock's flags 224/225 as HH:MM
LET 249 102
EXTERN 100 74      ; compare pair [100] with pair [102] into flag 251
```

Fns 72/73/75 add and subtract 16-bit pairs (flag 251 reports overflow);
fn 74 compares (0 less, 1 equal, 2 greater); fns 82/83 format HH:MM and
MM:SS. Four printing functions are also reachable through `CALL` slots
0-3 with the flag number in flag 249. The module's README has the full
worked status line.

A number printed as the last thing in an entry stays in the word
wrapper's buffer until a space, a newline or a `WINDOW` switch flushes
it.

## Contributing your extern

Written an extern other games could use? The collection above takes
community submissions - each ships as source plus a
prebuilt binary, so authors who cannot assemble can still use yours.
The submission requirements, the rules your code must obey and the
automated audit that checks them are described in `CONTRIBUTING.md` at
the root of the NextDAAD repository:
https://github.com/absent42/NextDAAD
