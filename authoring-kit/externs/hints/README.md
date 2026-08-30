# hints

A NextDAAD XBN worked example: hint text served from an SD card file,
so a game can ship a large hint book without spending DAAD message
slots or interpreter RAM on it.

`HINTS.TXT` is authored beside your game source and packed by
`BUILD.BAT` into `RELEASE\GAME.HNT`. The packer assigns each topic and
level its offset; the extern only reads what the packer wrote.

## EXTERN fn codes

- `EXTERN n 50` - print topic n's hint. With flag 242 = 0 (automatic),
  prints the topic's next unread level from `GAME.HPR` and advances it
  by one; if the advance fails to save, flag 243 reports 5 rather than
  0, even though the hint printed. With flag 242 nonzero, prints that
  level (1-based) instead and does not touch `GAME.HPR`.
- `EXTERN n 51` - level count for topic n, written into flag 243.
- `EXTERN 0 52` - preflight: opens `GAME.HNT`, validates its header, and
  reports whether the hint file is present and readable. Call this once
  near the start of the game so a broken or missing hint file degrades
  quietly instead of failing later, mid-hint.
- `EXTERN 0 53` - rewrites `GAME.HPR` blank, resetting every topic's
  automatic-mode progress to level 0. Independent of `LOAD`/`RESTART`,
  which do not touch it. Flag 243 reports 5, not 0, if the blank write
  fails - the file is then left in whatever state that write reached.

## Flags

- Flag 242 - level override. 0 means automatic: fn 50 reads the
  topic's next level from `GAME.HPR`, prints it, and stores level+1
  back. A nonzero value pins every topic to that level instead (1 =
  the first hint) and never touches `GAME.HPR`.
- Flag 243 - status after fn 50/52/53, or the level count after fn 51.

| Flag 243 after | Means |
|---|---|
| 0 | the hint printed, or the file is readable (fn 52), or fn 53 cleared progress |
| 1 | `GAME.HNT` missing, unreadable, or truncated - opening it (fn 50/52/53) failed, or fn 50's level-table entry could not be read |
| 2 | no such topic, or (automatic mode only) `GAME.HPR` could not be opened or read |
| 3 | no such level - the player has had every hint for this topic |
| 4 | this interpreter is older than the extern needs |
| 5 | `GAME.HPR` could not be written - fn 50 printed the hint but the new level was not saved, or fn 53 could not create/write a blank `GAME.HPR` and progress was not cleared |

After `EXTERN n 51`, flag 243 holds the topic's level COUNT instead. Zero
means "no hints available" - whether the topic does not exist or the hint file
is missing entirely. Fn 51 never reports a status code, because a code would be
indistinguishable from a count.

Each hint ends with a line break, emitted by the extern. That both flushes the
print path's word buffer, without which the hint's final word would not appear,
and gives you the paragraph break you would otherwise have to add yourself.

## Authoring rules

- Do not use `_` in hint text. `EXTERN` fn 50 prints through the
  interpreter's decoded-print path, where `_` is the object-name
  substitution used by every DAAD database, not a literal underscore.
- Do not use control bytes below `$20` in hint text - the same print
  path reads `$0B`/`$0C`/`$0E`/`$0F` as CLS, wait-key and graphics
  toggles, not printable characters.
- `hintpack.ps1` warns (does not fail the build) if a level breaks
  either rule, naming the topic and level, so you can find and fix it
  before shipping.

## Limits

Up to 256 topics, numbered 0-255. Up to 255 levels per topic. Up to
64KB of hint text in total across the whole file.

## About the obfuscation

The hint text in `GAME.HNT` is obfuscated, not encrypted. It defeats a
text editor, `type`, and `strings` - the casual "just read the
answers" path. It does not defeat a hex editor and a determined
player, and it is not meant to. That is the right bar for a hint file.

The obfuscation keystream is fixed and identical for every game built
with this kit - one small tool could decode any of them. That does
not weaken it: the bar above is stopping an accidental spoiler, not a
determined player, and a fixed scheme defeats an accidental open
exactly as well as a random one would.

Being fixed also means an author can ship a game update - new levels,
fixed typos, reworded hints - without invalidating players' existing
`GAME.HPR`: the seed never changes, so old progress still decodes
correctly against the new `GAME.HNT`. The one case that does not carry
over: if an update REMOVES levels so a topic ends up with fewer than a
player has already read, that topic reports flag 243 = 3 (no more
hints) for them from then on. `EXTERN 0 53` clears a player's progress
if that needs resetting.

Automatic-mode progress lives in `GAME.HPR` beside your game, not in
flags, so hint level costs the author no game flags at all. It does
not rewind on `LOAD` or `RESTART`, and it is shared by every save game
and every player using that card. A hint already read stays read.
`EXTERN 0 53` clears it, for a game that wants each playthrough to
start fresh. `GAME.HNT` itself is never written, so a power cut
mid-update can only ever damage the disposable `GAME.HPR` - never the
author's hint text. If `GAME.HPR` is missing, the next automatic-mode
call creates a fresh zeroed one; if it is present but unreadable at a
given topic, that call reports flag 243 = 2 rather than guessing. A
short read or a failed write is always reported rather than acted on
with whatever happened to be in RAM - flag 243 = 2 for a read that
came back wrong, flag 243 = 5 for a write that did not go through.
