# Services

Twenty-one routines in a fixed jump table at `XBN_API` (`$BEC8`), frozen from the
first shipping release: the address never moves, existing rows never change
signature, and new rows are only ever appended with a version bump. `xbn.inc`
binds a symbol to each row, so you `call SVC_PUTS` like any other subroutine.
Every row preserves your bank's own mapping across the call.

This is a summary. The full contract - the exact In, Out and Corrupts columns
for every row - is the table in
[the XBN format reference](../../../../docs/reference/xbn-format.html#service-table).
Read it before you rely on a register surviving a call; only the registers a
row's Out column names carry a result.

| # | Symbol | For | Hook-safe |
|---|--------|-----|-----------|
| 0 | `SVC_VERSION` | the API version in A (`3` on this release) | yes |
| 1 | `SVC_PUTCHAR` | print one character through the current DAAD window | no |
| 2 | `SVC_PUTS` | print an ASCIIZ string (it may live in your own bank) | no |
| 3 | `SVC_FOPEN` | open a file on the card, raw esxDOS mode byte in B | no |
| 4 | `SVC_FREAD` | read bytes from a handle into a buffer | no |
| 5 | `SVC_FWRITE` | write bytes from a buffer to a handle | no |
| 6 | `SVC_FSEEK` | seek a handle to a 32-bit offset | no |
| 7 | `SVC_FCLOSE` | close a handle | no |
| 8 | `SVC_RANDOM` | one random byte 0-255, from `CHANCE`'s own stream | yes |
| 9 | `SVC_GETMSG` | decode a user message into the shared staging buffer | no |
| 10 | `SVC_FRAMES` | the free-running, wrapping 50Hz frame counter | yes |
| 11 | `SVC_GETDATE` | the real-time clock, when the machine has one | no |
| 12 | `SVC_BUSY` | what the interpreter is in the middle of, as a bit mask | yes |
| 13 | `SVC_PALREAD` | copy a Layer 2 palette bank into your 512-byte buffer | no |
| 14 | `SVC_WINDOW` | select a DAAD window; returns the one that was current | no |
| 15 | `SVC_PAIR` | the tilemap attribute for a (paper, ink) pair, B = paper, C = ink | no |
| 16 | `SVC_GETLINE` | the line the player typed this turn, read-only | no |
| 17 | `SVC_GETPENDING` | orders left unconsumed after a conjunction | no |
| 18 | `SVC_INJECT` | queue a line for the very next `PARSE 0` | no |
| 19 | `SVC_VOCFIND` | resolve a word against the database vocabulary | no |
| 20 | `SVC_FITWORD` | make room for a word: flush, then wrap if it will not fit the line | no |

Errors follow the esxDOS convention throughout: carry set, error code in A.
Rows 15-20 are API version 3: gate any of them on `SVC_VERSION` first if your
extern must also run against an older `xbn.inc`.

## The hook rule

Four rows may be called from the `#int` hook - `SVC_VERSION`, `SVC_RANDOM`,
`SVC_FRAMES` and `SVC_BUSY`. They touch resident memory and never page. Every
other row runs the print path, the file system, a window switch or the shared
palette registers, none of which may be entered from interrupt context.

Never `halt` inside the hook. The frame interrupt's own source is masked while
its handler runs, so a `halt` there waits for an edge that cannot come - and
with a sampled effect playing, the sample interrupt would wake it after about
64 microseconds instead. Either way it is never a frame wait; gate on
`SVC_FRAMES` from the foreground.

The rest of the hook rules - keep it well under a frame, no `EI`, no zxnDMA,
no file IO, never install your own interrupt vector - are in the manual's
[#int hook section](../../../../docs/externs.html#the-int-hook). Read it
before writing a hook; it is short and every rule in it is load-bearing.

### Time comes from SVC_FRAMES, never from counting

`halt` is NOT a frame tick. The manual's
[#int hook section](../../../../docs/externs.html#the-int-hook) explains the
mechanism; the consequence is that a foreground wait which counts `halt`
returns can run up to 312 times fast. Gate on the counter instead, and bound
the wait. This sample is FOREGROUND code - the hook itself must never `halt`:

    ; bound in BC, so a stalled counter can never hang the game
        ld bc, 400              ; maximum frames to wait
        call SVC_FRAMES
        ld e, l                 ; snapshot the counter's low byte
    .wl:
        ; test the thing you are waiting for; jump out when it is done
        dec bc
        ld a, b
        or c
        jr z, .done             ; bound spent: never hang
    .edge:
        halt                    ; a wakeup only - the compare gates
        call SVC_FRAMES
        ld a, l
        cp e
        jr z, .edge             ; same frame: keep waiting
        ld e, l                 ; a real frame passed
        jr .wl
    .done:
        or a                    ; CF clear: this fn is an action
        ret

Compare a snapshot rather than reading the counter as absolute time: it is 16
bits and it wraps (`or a` / `sbc hl, de`). Frames the hook missed during a
long draw or a video clip are still counted, which is why timekeeping from
counter deltas stays honest where counting hook invocations does not. The
fade module's fn 43 and the clock and timer modules are the worked patterns.

### SVC_BUSY and the tilemap

Writing the tilemap at `$6000` from the hook is legitimate and race-free - the
interrupt handler never remaps that window on its own account - EXCEPT while a
video clip with an audio track is playing. From a clip's arm point to its
teardown the interpreter borrows that same window as the clip's audio feed
and suspends the hook for that same span, so a write from the hook can no
longer land there. During a clip's open and prefill, before the arm point,
the hook still runs and the tilemap is still the game's.

Call `SVC_BUSY` at the top of the hook and skip the frame while bit 0 is set:
emit nothing, advance nothing, so your output resumes where it stopped. Bit 1
is the SD card, bit 2 the interpreter's palette or reveal critical section,
and bit 3 whether a colour cycle is armed. Bits 0 and 2 read 0 from the
foreground - they are only ever observable from the hook - but bit 3 reads
the same from either context.

### The live text width

A game can switch between 80x32 and 40x32 text with `GFX n 18`, which changes
the tilemap row stride (160 bytes per row at 80 columns, 80 at 40). The width
is not part of the frozen ABI, so ask the hardware each time rather than
caching it. `xbnmod.inc`'s `xbn_width` is hook-safe and returns the width in
columns in E (80 or 40), the row stride in D (160 or 80) and a row-27 base in
HL; for any row use `XBN_TILEMAP + row * stride` (`xbnmod.inc`), as the
ticker's `tick_field` does. It corrupts AF, BC, DE, HL. From the foreground,
DI-bracket the call (IFF2-preserving, as the ticker's `tick_field` does): the
frame ISR re-selects $243B without restoring it. The ticker module calls it
every frame while armed, so a switch mid-message just carries on at the new
width.

### The palette interlock

If your hook programs the Layer 2 palette, go through `xbnmod.inc`'s owner
byte. Two hooks writing the palette in the same frame corrupt entries.

- `xbn_pal_acquire` with your module id in A, from the FOREGROUND call that
  starts the effect. Never acquire from a hook. Carry clear means you hold it.
- `xbn_pal_check` with your id in A, in the hook, before EVERY burst. Carry
  clear means it is still yours; otherwise skip the frame.
- `xbn_pal_release` with your id in A, from the call or hook that finishes.
  It frees the byte only if you are the owner.

Claim the next free id in the owner-byte comment in `xbnmod.inc` when you add
a module. The fade module is the worked pattern.

## Rows with rules attached

### SVC_GETMSG - the buffer is borrowed

`SVC_GETMSG` decodes a database user message into a shared,
interpreter-owned buffer and hands you its address in HL and its length in BC.
The buffer is valid only until the NEXT service call of any kind, or until the
next `SAVE`, `LOAD`, `RAMSAVE` or `RAMLOAD` - it is the same resident memory
that machinery stages through.

If the text must outlive the call that fetched it - anything the `#int` hook
reads frame by frame - copy it into memory your own bank owns before doing
anything else. That copy is the whole point of the ticker example.

Also true of it: the buffer caps at 256 bytes and longer messages are
truncated, with BC always matching what actually landed. Bytes come back
exactly as the database stores them, control codes intact and the `_`/`@`
object-name substitution NOT expanded. A message number out of range returns
carry set with A = `$FF` and the buffer untouched - and a legal but EMPTY
message returns carry clear with BC = 0, which is not an error but is also not
safe to hand to `LDIR`.

### SVC_WINDOW - selecting flushes

`SVC_WINDOW` selects a window 0-7 through the interpreter's own machinery and
returns the PREVIOUSLY selected window in A, so a printing routine can bracket
its own output: select the target, print, re-select what came back. A > 7
returns carry set and changes nothing.

Two effects to design around. Selecting a window FLUSHES the pending word of
the window you are leaving, so a `MES "Score "` issued just before your call
lands in the game window rather than beside your number - and that flush can
raise the More prompt THERE. And once you print into the target, an exact line
fill wraps and can raise More in the target, so size a status window for what
it actually holds. Window geometry stays the author's, set in DSF.

### SVC_PAIR - colours are pairs

A tilemap attribute names a (paper, ink) pair the interpreter allocates on
demand; only it can hand one out. A pair keeps its colours only while some
on-screen cell uses it, so resolve at the point of use and never cache an
attribute across a period when your cells are off screen - a `GFX n 18`
width switch blanks every cell, and is the named exception. The ticker
re-resolves at every arm. When one function needs both, call `SVC_PAIR`
BEFORE `SVC_GETMSG`: the staging buffer dies at the next service call.
Foreground-only. API version 3: gate it on `SVC_VERSION`, as the ticker's
arm does.

### SVC_PALREAD - which bank

`SVC_PALREAD` copies a Layer 2 palette bank into a 512-byte buffer at IX: 256
entries of two bytes, RRRGGGBB then a second byte masked to `%11000001` (bits
7-6 the priority field, bit 0 the blue LSB). IX ends at buffer+512.

A selects the bank: **0** is the bank the display is showing, **1** is the
other bank - which is where `DISPLAY` stages a picture's palette while buffer
mode (`GFX 0 4`) is open. With no buffer mode open there is no staged palette
to read, which is why the fade module's re-snapshot function needs the
`GFX 0 4` bracket around it.

### SVC_GETDATE - no clock is the normal case

Carry clear gives the MS-DOS packed date in BC, the packed time in DE and
seconds in H. Carry set means no RTC or an invalid reading: BC and DE are zero
and HL is UNDEFINED, so never read the seconds on that path. A machine with no
working clock is the case to write for, not an error to report.

### SVC_RANDOM - the shared stream

Uniform 0-255 from the same stream `CHANCE` and `RANDOM` use, so scale or mask
it yourself. It preserves BC, DE and HL, which is what makes the four-line
chance condition possible. It is hook-safe, but a hook draw consumes the
shared stream at a moment the game cannot predict: a game that must replay
identically cannot draw from the hook.

### SVC_GETLINE - the SAVE prompt never lands in it

`SVC_GETLINE` returns the line the player actually typed - HL points at the
interpreter's own recall buffer (read-only), BC is its length. Carry SET
means the prompt that just ran ended in a timeout or an empty `ENTER`; HL
then holds whatever the recall buffer already held (the partial line after
a timeout). Carry CLEAR covers a typed submit, an order taken after a
conjunction, and an injected turn (`SVC_INJECT`) - HL is always the last
line the player actually typed, never the injected text. A `SAVE`/`LOAD`
filename prompt stashes the typed line and restores it afterwards, so it
never reaches this buffer - an extern reading `SVC_GETLINE` after a `SAVE`
earlier in the same turn still gets the player's real command.

### SVC_GETPENDING - leading blanks are real

HL/BC give whatever a conjunction ("and", "then") left unconsumed - `LOOK
AND GET LAMP` leaves `GET LAMP` pending, but the parser blanks the
conjunction word IN PLACE, so the text is `"   GET LAMP"` with the leading
spaces still there. A module folding this into an injected line picks up
harmless extra spaces; do not strip them expecting a clean start.

### SVC_INJECT - replace semantics and the always-inject rule

`SVC_INJECT` queues text for the very next `PARSE 0`, bypassing the prompt.
It REPLACES any pending order already queued from a conjunction - read
`SVC_GETPENDING` first if you need to keep it. Option bit 0 echoes the text
as if typed. Refusal (over 127 characters, or a line already parked) sets
carry and A = `$FF` and writes NOTHING, options included - do not assume a
partial injection happened.

A rewriter called from a `PARSE` entry's own remainder must ALWAYS inject
something, even when it found nothing to change - inject the original line
unmodified, or the game's next `PARSE 0` prompts again with no visible
cause. The PRO 1 sketch below is the shape to copy:

    ; PRO 1: decide, then ALWAYS inject
        call decide_rewrite      ; HL = text to send, whether changed or not
        xor a                    ; options: no echo
        call SVC_INJECT
        ret                      ; CF from SVC_INJECT is refusal, not "changed"

A line hook is different: it rewrites the line IN PLACE, the buffer it was
handed, and returns a carry verdict - it never calls `SVC_INJECT`. Injecting
from the line hook overwrites `inpLine` mid-parse and parks an extra line
the next `PARSE 0` consumes as a phantom empty input.

Never call `SVC_INJECT` between a `PARSE 0` and the `PARSE 1` that reads the
same order's quoted section - it parks its text over the buffer `PARSE 1`
reads from and clobbers the quote.

### SVC_VOCFIND - foreground only, never from the output hook

Resolves a word against the database's own vocabulary, any case, first five
characters significant: D = word id, E = type, carry clear on a match, carry
set when the word is unknown. HL points at ONE word - a space or other
punctuation counts as an ordinary character toward the five, so pass a
single word, not a phrase. Foreground only, and more strictly than most
rows marked that way - never call it from the output hook either. The output
hook is not the `#int` hook, but the lookup reuses shared resident state that
a print already in flight is also using.

### SVC_FITWORD - typing with word wrap

`SVC_PUTCHAR` hands characters to the printer's word buffer, so text
appears a word at a time; a one-character `SVC_PUTS` shows each letter at
once but breaks words at the window edge. To type letter by letter with
real word wrap, call `SVC_FITWORD` with the length of the next word, then
print its letters one `SVC_PUTS` each. Count only characters that take a
cell: `$0E`/`$0F` charset toggles sit inside words (an accented letter is
`$0E chr $0F`) and have no width. A word containing `_` has a length only
the interpreter knows - send it with `SVC_PUTCHAR` and flush it with an
empty `SVC_PUTS`. `SVC_FITWORD` returns A = the current window's width. A
word as wide as the window or wider is placed by the printer in chunks of
the window width: call `SVC_FITWORD` before each chunk with that chunk's
length. The ticker's fn 39 is the worked pattern. Foreground-only.

### SVC_FWRITE - the short-write rule

BC on return is the number of bytes actually written - documented from API
version 3, though the row always returned it. A short count with carry
still CLEAR is esxDOS's seek-then-extend hazard: the write landed short of
what you asked for without the call failing outright. Treat a short count
exactly as you would treat carry set - never assume a clear carry alone
means the whole buffer landed.

### File mode constants

`xbn.inc` defines the raw esxDOS mode byte for `SVC_FOPEN`'s B:

| Symbol | Value | For |
|--------|-------|-----|
| `XBN_FMODE_R` | `$01` | read |
| `XBN_FMODE_RW` | `$03` | existing file, read/write, no truncate |
| `XBN_FMODE_W` | `$0E` | write, create or truncate |

## Checking the version

`SVC_VERSION` returns `3` on this release. Because the table is append-only,
code written against an older `xbn.inc` keeps calling the same rows forever.
An extern that needs a row its `xbn.inc` did not ship with checks first and
fails gracefully instead of jumping into whatever used to live there:

    MIN_API equ 3
    preflight:
        call SVC_VERSION
        cp MIN_API
        jr nc, .ok
        scf                 ; older interpreter: the condition fails
        ret
    .ok:
        ; ...

The format version (the header's byte 3) and the API version are the same
number on this release but are separate contracts: the loader enforces the
first, your code checks the second.

Full detail: the manual's [Services section](../../../../docs/externs.html#services)
and [Versioning](../../../../docs/externs.html#versioning).
