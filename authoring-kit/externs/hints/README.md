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
  by one: printed; if the progress save fails the hint may reprint next
  time. With flag 242 nonzero, prints that level (1-based) instead and
  does not touch `GAME.HPR`. CF set means no further hint to give: no
  such topic, no such level, or `GAME.HNT` is unavailable.
- `EXTERN n 51` - level count for topic n, written into flag 243. An
  action: always CF clear, including when the topic has no levels
  (writes 0).
- `EXTERN 0 52` - preflight: opens `GAME.HNT` and validates its header.
  Call this once near the start of the game so a broken or missing hint
  file degrades quietly instead of failing later, mid-hint. CF set means
  the hint book is unavailable - missing, unreadable, truncated, or this
  interpreter predates the module's minimum API (`MIN_API`, checked via
  `SVC_VERSION` - the manual's own worked example of interpreter
  versioning).
- `EXTERN 0 53` - rewrites `GAME.HPR` blank, resetting every topic's
  automatic-mode progress to level 0. Independent of `LOAD`/`RESTART`,
  which do not touch it. CF set means the reset did not take - the file
  is left in whatever state that write reached.

## Flags

- Flag 242 - level override. 0 means automatic: fn 50 reads the
  topic's next level from `GAME.HPR`, prints it, and stores level+1
  back. A nonzero value pins every topic to that level instead (1 =
  the first hint) and never touches `GAME.HPR`.
- Flag 243 - the level count after fn 51. Fn 50/52/53 report through CF
  only and never touch this flag.

After `EXTERN n 51`, flag 243 holds the topic's level COUNT. Zero means
"no hints available" - whether the topic does not exist or the hint file
is missing entirely. Fn 51 never reports a status code, because a code
would be indistinguishable from a count.

Each hint ends with a line break, emitted by the extern. That both flushes the
print path's word buffer, without which the hint's final word would not appear,
and gives you the paragraph break you would otherwise have to add yourself.

## Authoring rules

- Do not use `_` in hint text. `EXTERN` fn 50 prints through the
  interpreter's decoded-print path, where `_` is the object-name
  substitution used by every DAAD database, not a literal underscore.
- Do not type control bytes below `$20` in hint text - the same print
  path reads `$0B`/`$0C`/`$0E`/`$0F` as CLS, wait-key and graphics
  toggles, not printable characters. This is about bytes you type: the
  accent conversion below legitimately emits `$0E`/`$0F` triples in
  the packed output.
- Accented Latin-1 characters are converted the same way the DAAD
  compiler converts them in game text, so a hint prints identically to
  a compiled message with the same accent. Lowercase acute vowels, plus
  n-tilde, c-cedilla and u-diaeresis in EITHER case, and a few
  punctuation marks convert to one byte; every other accented character
  in the compiler's table converts to a three-byte sequence;
  sharp-s (the German eszett, Latin-1 `$DF`) converts to one byte. A
  Latin-1 character outside this set is not converted - some accented
  letters have no entry in the compiler's own table - and packs as its
  raw Latin-1 byte, which prints as an unrelated glyph, not the
  intended accent.
- `hintpack.ps1` warns (does not fail the build) if a level breaks any
  of the rules above, naming the topic and level - and, for an
  unsupported character, its byte value - so you can find and fix it
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
player has already read, `EXTERN n 50` fails (CF set: no further hint)
for them from then on. `EXTERN 0 53` clears a player's progress if that
needs resetting.

Automatic-mode progress lives in `GAME.HPR` beside your game, not in
flags, so hint level costs the author no game flags at all. It does
not rewind on `LOAD` or `RESTART`, and it is shared by every save game
and every player using that card. A hint already read stays read.
`EXTERN 0 53` clears it, for a game that wants each playthrough to
start fresh. `GAME.HNT` itself is never written, so a power cut
mid-update can only ever damage the disposable `GAME.HPR` - never the
author's hint text. If `GAME.HPR` is missing, the next automatic-mode
call creates a fresh zeroed one; if it is present but unreadable at a
given topic, `EXTERN n 50` fails (CF set) rather than guessing - a
failed read is always reported that way rather than acted on with
whatever happened to be in RAM. A failed WRITE is different: the hint
has already printed by the time the level save is attempted, so a
write failure does not fail the entry - it is a success, and the same
level may print again on the next call.
