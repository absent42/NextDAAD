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
  by one. With flag 242 nonzero, prints that level (1-based) instead
  and does not touch `GAME.HPR`.
- `EXTERN n 51` - level count for topic n, written into flag 243.
- `EXTERN 0 52` - preflight: opens `GAME.HNT`, validates its header, and
  reports whether the hint file is present and readable. Call this once
  near the start of the game so a broken or missing hint file degrades
  quietly instead of failing later, mid-hint.
- `EXTERN 0 53` - rewrites `GAME.HPR` blank, resetting every topic's
  automatic-mode progress to level 0. Independent of `LOAD`/`RESTART`,
  which do not touch it.

## Flags

- Flag 242 - level override. 0 means automatic: fn 50 reads the
  topic's next level from `GAME.HPR`, prints it, and stores level+1
  back. A nonzero value pins every topic to that level instead (1 =
  the first hint) and never touches `GAME.HPR`.
- Flag 243 - status after fn 50/52/53, or the level count after fn 51.

| Flag 243 after | Means |
|---|---|
| 0 | the hint printed, or the file is readable (fn 52), or fn 53 cleared progress |
| 1 | `GAME.HNT` missing or unreadable |
| 2 | no such topic, or (automatic mode only) `GAME.HPR` could not be opened or read |
| 3 | no such level - the player has had every hint for this topic |
| 4 | this interpreter is older than the extern needs |

After `EXTERN n 51`, flag 243 holds the topic's level COUNT instead. Zero
means "no hints available" - whether the topic does not exist or the hint file
is missing entirely. Fn 51 never reports a status code, because a code would be
indistinguishable from a count.

Each hint ends with a line break, emitted by the extern. That both flushes the
print path's word buffer, without which the hint's final word would not appear,
and gives you the paragraph break you would otherwise have to add yourself.

## Limits

Up to 256 topics, numbered 0-255. Up to 255 levels per topic. Up to
64KB of hint text in total across the whole file.

## About the obfuscation

The hint text in `GAME.HNT` is obfuscated, not encrypted. It defeats a
text editor, `type`, and `strings` - the casual "just read the
answers" path. It does not defeat a hex editor and a determined
player, and it is not meant to. That is the right bar for a hint file.

Automatic-mode progress lives in `GAME.HPR` beside your game, not in
flags, so hint level costs the author no game flags at all. It does
not rewind on `LOAD` or `RESTART`, and it is shared by every save game
and every player using that card. A hint already read stays read.
`EXTERN 0 53` clears it, for a game that wants each playthrough to
start fresh. `GAME.HNT` itself is never written, so a power cut
mid-update can only ever damage the disposable `GAME.HPR` - never the
author's hint text. If `GAME.HPR` is missing, the next automatic-mode
call creates a fresh zeroed one; if it is present but unreadable at a
given topic, that call reports flag 243 = 2 rather than guessing.
