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

## How to build

A prebuilt `GAME.XBN` ships in this directory - copy it next to your
own `GAME.DDB` (or use the combined collection binary, which includes
it). To rebuild after editing the source (build.ps1 finds sjasmplus via
its -SjasmPlus parameter, then the kit's tools\sjasmplus\, then PATH;
https://github.com/z00m128/sjasmplus):

    .\build.ps1

This assembles `transcript.asm` and rewrites `GAME.XBN` here.

## Functions

| Call | Effect | Fails (CF set) |
|---|---|---|
| `EXTERN 1 90` | start recording, full mode (typed lines and printed text) | interpreter predates API 3, or the file cannot be created |
| `EXTERN 0 90` | start recording, input-only mode (typed lines only - a replayable walkthrough script) | as above |
| `EXTERN 0 91` | stop: flush and disarm | never |
| `EXTERN 0 92` | condition: CF clear while recording | CF set when not recording, or after a flush failure |
| `EXTERN n 93` | write user message n into the file as a `##` label line, for run sheets ("step 4" markers a diff can anchor on) | never (no-op if not recording) |
| `EXTERN w 94` | record window w (0-7) only; 255 (the default after start) records every window | never |

## File format

Plain text, `$0D` line ends, in the game's own folder (8.3 name, no
long-filename dependency):

- `## ...` - a header line (start) or a label line (`EXTERN n 93`).
- `>>text` - a typed line, queued by the line hook before the parse.
- `~` - overflow sentinel: the ring filled mid-turn, the rest of that
  turn's text was dropped. The next line hook resumes normally.

## Latency and the ring

The typed-line queue and printed-text tap both write into a bank
scratch ring (`TRANSCRIPT_RING`, default 2048 bytes; override the
define before including this module in a standalone build for more
headroom - the combined collection binary needs the smaller default).
The ring drains only at the next line hook (or at `EXTERN 0 91`): one
open-seek-write-close round trip to the card per turn, before that
turn's response. That is the trade for crash safety - a transcript
that dies with the crash it was meant to document is worthless.
Everything one turn prints must fit in the ring; a room description
plus a LISTOBJ is on the order of 1K.

## Input-only mode

`EXTERN 0 90` records typed lines only, none of the game's own output -
a walkthrough script another run can replay, without the printed text
bloating the file or drifting between print-width settings.
