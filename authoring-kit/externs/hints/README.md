# hints

A NextDAAD XBN worked example: hint text served from an SD card file,
so a game can ship a large hint book without spending DAAD message
slots or interpreter RAM on it.

`HINTS.TXT` is authored beside your game source and packed by
`BUILD.BAT` into `RELEASE\GAME.HNT`. The packer assigns each topic and
level its offset; the extern only reads what the packer wrote.

## EXTERN fn codes

- `EXTERN n 50` - print the next unread hint for topic n. Advances that
  topic's progress by one level.
- `EXTERN n 51` - level count for topic n, written into flag 243.
- `EXTERN 0 52` - preflight: opens `GAME.HNT`, validates its header, and
  reports whether the hint file is present and readable. Call this once
  near the start of the game so a broken or missing hint file degrades
  quietly instead of failing later, mid-hint.
- `EXTERN 0 53` - clear all progress, so a game can offer "start hints
  over" independently of `LOAD`/`RESTART`.

## Flags

- Flag 242 - level override. 0 means automatic: the extern advances
  each topic's own level counter as fn 50 is called. A nonzero value
  pins every topic to that level instead.
- Flag 243 - status after fn 50/52/53, or the level count after fn 51.
  Status values: 0 ok, 1 no file (missing, unreadable or truncated
  `GAME.HNT`), 2 no topic (absent or above the file's maxTopic), 3 no
  level (past this topic's ceiling), 4 old API (the interpreter predates
  the file services this module needs).

## Limits

Up to 256 topics, numbered 0-255. Up to 255 levels per topic. Up to
64KB of hint text in total across the whole file.

## About the obfuscation

The hint text in `GAME.HNT` is obfuscated, not encrypted. It defeats a
text editor, `type`, and `strings` - the casual "just read the
answers" path. It does not defeat a hex editor and a determined
player, and it is not meant to. That is the right bar for a hint file.

Hint progress lives in `GAME.HPR` beside your game, not in flags. It
does not rewind on `LOAD`, and it is shared by every save game and
every player using that card. A hint already read stays read. `EXTERN
0 53` clears it, for a game that wants each playthrough to start
fresh.
