# Transcript - NextDAAD XBN worked example

## What it does

Records every typed line and every printed character to `TRANS.TXT` in
the game's own folder, written by the interpreter the player actually
ran. On hardware that gives a walkthrough recorder and a bug report
that writes itself; for testing it gives a file diff instead of a
tilemap read. Needs a v0.10.1 interpreter (format 3 header, line and
output hooks) - an older interpreter loads the game with the module
off.

Recording is a session activity: state (armed, mode, window filter,
running length, error) is bank scratch, not a flag and not the extern
state area. A LOAD mid-recording is harmless; RESTART and a part switch
leave it armed.

A game ships with this module only when it means to - the file grows
without bound for as long as recording stays armed.

This module is NOT in `externs\all\GAME.XBN`. A binary with an output
hook pays a cost on every printed character - two DI-bracketed MMU
reads, a bank map, the chain call, a restore - whether or not it is
recording, because the loader arms the tap for any binary whose header
names an outEntry at all. The collection stays a plain format 2 binary
so every game using it prints at no such cost; include this module only
in a game that actually records.

## How to build

A prebuilt `GAME.XBN` ships in this directory - copy it next to your
own `GAME.DDB`. To build a smaller binary that combines it with other
modules, run `EXTERNS.BAT transcript ...` from the kit root (see the
collection README). To rebuild after editing the source (build.ps1
finds sjasmplus via its -SjasmPlus parameter, then the kit's
tools\sjasmplus\, then PATH; https://github.com/z00m128/sjasmplus):

    .\build.ps1

This assembles `transcript.asm` and rewrites `GAME.XBN` here.

## Functions

| Call | Effect | Fails (CF set) |
|---|---|---|
| `EXTERN mode 90` | start recording (mode is a bitmask - see below) | interpreter predates API 3, or the file cannot be created |
| `EXTERN 0 91` | stop: flush and disarm | never |
| `EXTERN 0 92` | condition: CF clear while recording | CF set when not recording, or after a flush failure |
| `EXTERN n 93` | write user message n into the file as a `##` label line, for run sheets ("step 4" markers a diff can anchor on) | never (no-op if not recording) |
| `EXTERN w 94` | record window w (0-7) only; 255 (the default after start) records every window | never |

### fn 90's mode bitmask

- bit 0: 1 = full (typed lines and printed text), 0 = input only
  (typed lines only - a replayable walkthrough script, none of the
  game's own output).
- bit 1: 1 = no date - the header omits the `SVC_GETDATE` call and
  its stamp. Some emulators (ZEsarUX's esxdos handler) hang on that
  call; set this bit for any headless/emulator run. Real hardware and
  a real RTC only need it when the date is not wanted in the file.
  Setting this bit makes an emulator run safe, not faithful: ZEsarUX's
  esxDOS emulation keeps only the last open-seek-write-close cycle of a
  reopened file, zero-filling every earlier flush's region, so a
  multi-turn transcript is only faithful on real hardware regardless of
  this bit.

`EXTERN 1 90` - full, dated (silicon only). `EXTERN 3 90` - full,
no-date (emulator-safe). `EXTERN 2 90` - input-only, no-date. `EXTERN
0 90` - input-only, dated (silicon only).

## File format

Plain text, `$0D` line ends, in the game's own folder (8.3 name, no
long-filename dependency):

- `## ...` - a header line (start) or a label line (`EXTERN n 93`).
  The header reads one of:
  - `## NextDAAD transcript YYYY-MM-DD HH:MM` - dated (mode bit 1 clear).
  - `## NextDAAD transcript no-rtc` - dated was asked for but the
    interpreter found no RTC.
  - `## NextDAAD transcript no-date` - mode bit 1 set: `SVC_GETDATE`
    was never called.
- `>>text` - a typed line, queued by the line hook before the parse. A
  line injected with `SVC_INJECT` gets no marker of its own - the line
  hook is not called for it - so during playback its output joins the
  previous typed turn.
- `~` - overflow sentinel: the ring filled mid-turn, the rest of that
  turn's OUTPUT was dropped. The typed-line marker for the NEXT
  command is never among the dropped bytes - see "Latency and the
  ring" below.

## Latency and the ring

The typed-line queue and printed-text tap both write into a bank
scratch ring (`TRANSCRIPT_RING`, default 2048 bytes; a subset build
combining this module with others needs the smaller default to stay
inside the 16K bank - override the define before including this
module in a standalone build for more headroom).
The ring drains only at the next line hook (or at `EXTERN 0 91`): one
open-seek-write-close round trip to the card per turn, before that
turn's response. That is the trade for crash safety - a transcript
that dies with the crash it was meant to document is worthless.
Everything one turn prints must fit in the ring; a room description
plus a LISTOBJ is on the order of 1K.

Printed output and the next typed line share the ring but not the same
cap: the output tap stops short of the true end, reserving enough room
for the largest possible line-hook marker (a 127-character line plus
its `\r>>...\r` wrapping). Output that reaches its cap gets one `~`
and the rest of that turn's OUTPUT is dropped; the typed-line marker
for the turn after it is never among the casualties - the file may
lose what a turn printed, never what the player typed next.

## Input-only mode

Mode bit 0 clear (`EXTERN 0 90` or `EXTERN 2 90`) records typed lines
only, none of the game's own output - a walkthrough script another run
can replay, without the printed text bloating the file or drifting
between print-width settings.
