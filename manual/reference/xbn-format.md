# XBN format

The binary layout `GAME.XBN` must follow, the checks the loader applies
to it, and the frozen addresses author code relies on. See
[Externs](../externs.md) for how to build and use one; this page is the
format itself.

## Header

Fourteen bytes at the start of the file, loaded to `$C000`:

| Offset | Size | Field | Meaning |
|--------|------|-------|---------|
| 0 | 3 | magic | `"XBN"` |
| 3 | 1 | version | Format version - `2` |
| 4 | 2 | extEntry | `EXTERN`/`CALL` entry address, `$C000`-`$FFFF`, or `0` for none |
| 6 | 2 | intEntry | 50Hz frame-hook entry address, or `0` for none |
| 8 | 2 | size | Total byte count, header included, up to `$4000` |
| 10 | 4 | reserved | Must be zero. A later format may make one of these bytes load-bearing; a version 2 loader rejects any nonzero value so that change can land without another version cliff |

`xbn.inc`'s `XBN_HEADER` macro emits this for you from two labels (or
`0`), reserved bytes included; you never build it by hand. Collection
modules use `xbnmod.inc`'s `XBN_BEGIN` instead, which emits the same
header followed by the `CALL` slot table at `$C00E` (see
[Externs](../externs.md#one-binary-any-subset)).

A version 1 binary (ten-byte header, version byte `1`) is rejected by
this interpreter and the game plays with externs off: rebuild it against
the current `xbn.inc`. The other direction is equally closed - an
interpreter that predates format 2 rejects a version 2 file.

## Validation

The loader checks a `GAME.XBN` it finds at boot, in this order, and
rejects the file - freeing anything it had already allocated and
leaving the game to play with externs off - on the first check that
fails:

1. The file is no larger than 16384 bytes (`$4000`) on disk.
2. The file holds at least the fourteen header bytes (a shorter file is
   truncated).
3. The magic bytes read exactly `"XBN"`.
4. The version byte reads `2`.
5. The four reserved bytes at offsets 10-13 are all zero.
6. The size field is no larger than `$4000`.
7. The size field matches the number of bytes actually read from the
   file - a size field that disagrees with the real file length is
   rejected, whichever way it disagrees.
8. Each of `extEntry` and `intEntry` is either `0` (unused - always
   valid) or a genuine address strictly inside the loaded binary's
   extent (`$C000` up to, but not including, `$C000 + size`).

Any rejection is silent in a Release build - the game plays exactly as
it would with no `GAME.XBN` present at all, with no error shown to the
player. A DEBUG build prints a rejection marker on the boot screen. No
partially-valid state is ever committed: a file that fails validation
never has its entry points wired up, whatever they contained.

A `GAME.XBN` with both `extEntry` and `intEntry` set to `0` is legal and
loads without complaint - it simply never gets called, by anything.

Absent file (no `GAME.XBN` next to `GAME.DDB` at all) is not a rejection
in the sense above - it is the ordinary "feature off" case, indistinguishable
from a game that never used externs.

### The size-$4000 edge case

A binary whose `size` field is exactly `$4000` - the maximum - loads
with its usable range clamped to end at `$FFFF` rather than wrapping.
`$C000 + $4000` is `$10000`, one past the top of addressable memory;
the interpreter treats the window as ending at `$FFFF` inclusive in
that case. The one byte this affects is the very last byte of a
maximum-size binary: it is loaded and present, but it is not a valid
`CALL` target or entry-point address in its own right, since nothing
can address a location past `$FFFF` to call into.

## Service table

A fixed jump table of fifteen three-byte `JP` instructions at `XBN_API`
(`$BEC8`), frozen from the first shipping release. The address never
moves and existing rows never change signature or meaning - only new
rows are ever added, at the end, with a version bump reported by
`SVC_VERSION`. This is the same frozen-entry-point discipline esxDOS
and NextZXOS use for their own jump tables, so a game built against an
old `xbn.inc` keeps working unmodified on every future NextDAAD release.

| # | Symbol | In | Out | Corrupts | From the `#int` hook |
|---|--------|----|-----|----------|----------------------|
| 0 | `SVC_VERSION` | - | A = API version (`2` on this release) | AF | yes |
| 1 | `SVC_PUTCHAR` | A = character | - | AF, BC, DE, HL, IX, IY | no |
| 2 | `SVC_PUTS` | HL = ASCIIZ string (may live in your own bank) | - | AF, BC, DE, HL, IX, IY | no |
| 3 | `SVC_FOPEN` | IX = ASCIIZ filename, B = mode | A = handle, or CF set + A = error | AF, BC, DE, HL, IX, IY | no |
| 4 | `SVC_FREAD` | A = handle, IX = buffer, BC = length | BC = bytes read, or CF set + A = error | AF, BC, DE, HL, IX, IY | no |
| 5 | `SVC_FWRITE` | A = handle, IX = buffer, BC = length | CF set + A = error, on failure | AF, BC, DE, HL, IX, IY | no |
| 6 | `SVC_FSEEK` | A = handle, BCDE = offset | CF set + A = error, on failure | AF, BC, DE, HL, IX, IY | no |
| 7 | `SVC_FCLOSE` | A = handle | - | AF, BC, DE, HL, IX, IY | no |
| 8 | `SVC_RANDOM` | - | A = random byte (full range, not the 1-100 `CHANCE` scale) | AF only; BC, DE, HL preserved | yes |
| 9 | `SVC_GETMSG` | A = user message number | HL = buffer, BC = length (max 256, truncated); CF set + A = `$FF` when the number is out of range (the buffer is not written) | AF, BC, DE, HL, IX, IY | no |
| 10 | `SVC_FRAMES` | - | HL = the interpreter's free-running 50Hz frame counter, 16 bits, wrapping. Compare against a snapshot; never read it as absolute time | AF, HL | yes |
| 11 | `SVC_GETDATE` | - | CF clear: BC = MS-DOS packed date, DE = MS-DOS packed time, H = seconds, L = hundredths (`$FF` if the RTC has none). CF set = no RTC or invalid: BC = DE = 0 and HL is undefined - never read the seconds on that path | AF, BC, DE, HL, IX, IY (esxDOS row) | no |
| 12 | `SVC_BUSY` | - | A = busy bits: bit 0 a video clip is playing, bit 1 the SD card is busy, bit 2 the interpreter is inside its palette or reveal critical section. Unassigned bits read 0. Bits 0 and 2 are only ever observable from the hook | AF, L | yes |
| 13 | `SVC_PALREAD` | IX = 512-byte buffer, A = bank select: 0 the bank the display shows, 1 the other bank (the staged palette while `GFX 0 4` buffer mode is open) | 256 entries of two bytes: RRRGGGBB, then a second byte masked to `%11000001` (bits 7-6 the priority field, bit 0 the blue LSB); IX ends at buffer+512 | AF, BC, E, IX | no |
| 14 | `SVC_WINDOW` | A = window number 0-7 | selects that window through the interpreter's own machinery and returns A = the previously selected window; CF set and no change for A > 7. Selecting flushes the pending word of the window being left and may raise the More prompt there | AF, BC, DE, HL, IX, IY | no |

Error convention throughout is esxDOS style: carry flag set, error code
in A. A row's Corrupts column is its contract; only the registers its
Out column names carry a result. Every service preserves the caller's
own MMU mapping across the call - your extern's bank is back under
`$C000` when a service returns, whatever paging it did internally.

The last column is the hook rule. Rows marked yes are the only services
the `#int` hook may call (they touch resident memory only and never page);
every other row is foreground-only, because it runs the print path, the
file system, a window switch or the shared palette registers, none of
which may be entered from interrupt context. See [Externs](../externs.md#the-int-hook).

`SVC_GETMSG`'s buffer is interpreter-owned resident memory, shared with
other machinery, and is only guaranteed valid until the next service
call or the next save/load - see [Externs](../externs.md#services).

`SVC_RANDOM` draws from the same stream as `CHANCE` and `RANDOM`. A draw
from the hook consumes that stream at a time the game cannot predict, so
a game that needs reproducible runs must not draw from the hook.

## Frozen data anchors

Fixed addresses `xbn.inc` binds symbols to, none of which move between
releases:

| Symbol | Address | Meaning |
|--------|---------|---------|
| `XBN_FLAGS` | `$A200` | Base of the 256 DAAD flags - also where `IX` points on entry to your `EXTERN`/`CALL`/`#int` code |
| `XBN_OBJTABLE` | `$A300` | Base of the object table |
| `OBJ_SIZE` | `6` | Bytes per object table entry: `+0` location, `+1` weight/attribute bits, `+2`/`+3` extended attributes in flag order - `+3` holds attribute bits 0-7, `+2` holds bits 8-15, `+4` noun ID, `+5` adjective ID |
| `XBN_NUMOBJ` | `$A900` | The object count: one byte, the number of entries in the object table. Walk `0` to `XBN_NUMOBJ - 1`; entries past the count are stale |
| `XBN_API` | `$BEC8` | Base of the service jump table |

`XBN_API` grew to fifteen rows in format 2; rows 0-9 kept their
addresses and signatures.

## Limits

- **16384 bytes (`$4000`) maximum**, header included, for the whole
  `GAME.XBN` file.
- **256 bytes maximum** for a single `SVC_GETMSG` result; longer
  messages are truncated, not rejected.
- **One `GAME.XBN` per game.** There is no per-part extern file - the
  same binary stays loaded across every part switch.

See [Limits](limits.md) for these alongside the interpreter's other
size ceilings.
