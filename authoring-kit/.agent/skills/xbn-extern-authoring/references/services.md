# Services

Fifteen routines in a fixed jump table at `XBN_API` (`$BEC8`), frozen from the
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
| 0 | `SVC_VERSION` | the API version in A (`2` on this release) | yes |
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

Errors follow the esxDOS convention throughout: carry set, error code in A.

## The hook rule

Four rows may be called from the `#int` hook - `SVC_VERSION`, `SVC_RANDOM`,
`SVC_FRAMES` and `SVC_BUSY`. They touch resident memory and never page. Every
other row runs the print path, the file system, a window switch or the shared
palette registers, none of which may be entered from interrupt context.

Never `halt` inside the hook: interrupts are disabled while it runs, so a
`halt` there never wakes and the game hangs.

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
video clip with an audio track is playing. For the clip's whole duration the
interpreter borrows that same window as the clip's audio feed, and the hook
keeps firing. A write from the hook during that span lands in the audio buffer
and corrupts the clip's sound.

Call `SVC_BUSY` at the top of the hook and skip the frame while bit 0 is set:
emit nothing, advance nothing, so your output resumes where it stopped. Bit 1
is the SD card, bit 2 the interpreter's palette or reveal critical section.
Bits 0 and 2 read 0 from the foreground - they are only ever observable from
the hook.

### The live text width

A game can switch between 80x32 and 40x32 text with `GFX n 18`, which changes
the tilemap row stride (160 bytes per row at 80 columns, 80 at 40). The width
is not part of the frozen ABI, so ask the hardware each time rather than
caching it. `xbnmod.inc`'s `xbn_width` is hook-safe and returns the width in
columns in E (80 or 40), the row stride in D (160 or 80) and the bottom-row
base in HL. It corrupts AF, BC, DE, HL - park a counter you keep in BC before
the call, as the ticker does. The ticker module calls it per character, so a
switch mid-message just carries on at the new width.

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

## Checking the version

`SVC_VERSION` returns `2` on this release. Because the table is append-only,
code written against an older `xbn.inc` keeps calling the same rows forever.
An extern that needs a row its `xbn.inc` did not ship with checks first and
fails gracefully instead of jumping into whatever used to live there:

    MIN_API equ 2
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
