# XBN format

The binary layout `GAME.XBN` must follow, the checks the loader applies
to it, and the frozen addresses author code relies on. See
[Externs](../externs.md) for how to build and use one; this page is the
format itself.

## Header

Ten bytes at the start of the file, loaded to `$C000`:

| Offset | Size | Field | Meaning |
|--------|------|-------|---------|
| 0 | 3 | magic | `"XBN"` |
| 3 | 1 | version | Format version - `1` |
| 4 | 2 | extEntry | `EXTERN`/`CALL` entry address, `$C000`-`$FFFF`, or `0` for none |
| 6 | 2 | intEntry | 50Hz frame-hook entry address, or `0` for none |
| 8 | 2 | size | Total byte count, header included, up to `$4000` |

`xbn.inc`'s `XBN_HEADER` macro emits this for you from two labels (or
`0`); you never need to build it by hand.

## Validation

The loader checks a `GAME.XBN` it finds at boot, in this order, and
rejects the file - freeing anything it had already allocated and
leaving the game to play with externs off - on the first check that
fails:

1. The file is no larger than 16384 bytes (`$4000`) on disk.
2. The magic bytes read exactly `"XBN"`.
3. The version byte reads `1`.
4. The size field is no larger than `$4000`.
5. The size field matches the number of bytes actually read from the
   file - a size field that disagrees with the real file length is
   rejected, whichever way it disagrees.
6. Each of `extEntry` and `intEntry` is either `0` (unused - always
   valid) or a genuine address strictly inside the loaded binary's
   extent (`$C000` up to, but not including, `$C000 + size`).

Any rejection is silent in a Release build - the game plays exactly as
it would with no `GAME.XBN` present at all, with no error shown to the
player. A DEBUG build reports the reason on the boot screen. No
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

A fixed jump table of ten three-byte `JP` instructions at `XBN_API`
(`$BEC8`), frozen from the first shipping release. The address never
moves and existing rows never change signature or meaning - only new
rows are ever added, at the end, with a version bump reported by
`SVC_VERSION`. This is the same frozen-entry-point discipline esxDOS
and NextZXOS use for their own jump tables, so a game built against an
old `xbn.inc` keeps working unmodified on every future NextDAAD release.

| # | Symbol | In | Out |
|---|--------|----|----|
| 0 | `SVC_VERSION` | - | A = API version |
| 1 | `SVC_PUTCHAR` | A = character | - |
| 2 | `SVC_PUTS` | HL = ASCIIZ string | - |
| 3 | `SVC_FOPEN` | IX = ASCIIZ filename, B = mode | A = handle, or CF set + A = error |
| 4 | `SVC_FREAD` | A = handle, IX = buffer, BC = length | BC = bytes read, or CF set + A = error |
| 5 | `SVC_FWRITE` | A = handle, IX = buffer, BC = length | CF set + A = error, on failure |
| 6 | `SVC_FSEEK` | A = handle, BCDE = offset | CF set + A = error, on failure |
| 7 | `SVC_FCLOSE` | A = handle | - |
| 8 | `SVC_RANDOM` | - | A = random byte (full range, not the 1-100 `CHANCE` scale) |
| 9 | `SVC_GETMSG` | A = user message number | HL = buffer, BC = length (max 256, truncated), or CF set + A = `$FF` |

Error convention throughout is esxDOS style: carry flag set, error code
in A. Every row may clobber AF, BC, DE, HL and IX; only the registers a
row's Out column names carry a meaningful result. Every service
preserves the caller's own MMU mapping across the call - your extern's
bank is back under `$C000` when a service returns, whatever paging it
did internally.

All ten rows are foreground-only: none may be called from the `#int`
frame hook (see [Externs](../externs.md#the-int-hook)).

`SVC_GETMSG`'s buffer is interpreter-owned resident memory, shared with
other machinery, and is only guaranteed valid until the next service
call or the next save/load - see
[Externs](../externs.md#services) for what that means in practice.

## Frozen data anchors

Fixed addresses `xbn.inc` binds symbols to, none of which move between
releases:

| Symbol | Address | Meaning |
|--------|---------|---------|
| `XBN_FLAGS` | `$A200` | Base of the 256 DAAD flags - also where `IX` points on entry to your `EXTERN`/`CALL`/`#int` code |
| `XBN_OBJTABLE` | `$A300` | Base of the object table |
| `OBJ_SIZE` | `6` | Bytes per object table entry: `+0` location, `+1` weight/attribute bits, `+2`/`+3` extended attributes, `+4` noun ID, `+5` adjective ID |
| `XBN_API` | `$BEC8` | Base of the service jump table |

## Limits

- **16384 bytes (`$4000`) maximum**, header included, for the whole
  `GAME.XBN` file.
- **256 bytes maximum** for a single `SVC_GETMSG` result; longer
  messages are truncated, not rejected.
- **One `GAME.XBN` per game.** There is no per-part extern file - the
  same binary stays loaded across every part switch.

See [Limits](limits.md) for these alongside the interpreter's other
size ceilings.
