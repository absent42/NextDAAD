# Platform notes

How a DAAD game behaves on the ZX Spectrum Next, in the places where
this target is not quite like the other machines DAAD runs on.

Nothing on this page is going to change. Some of it is forced by the
hardware - text lives on the tilemap here and pictures live on Layer 2,
which are two separate surfaces rather than one screen. The rest is
settled by choice. Either way, this is how the target works, and it is
what to read first when a game behaves differently here than it did
somewhere else.

For behaviour that is *not* settled - differences we mean to remove -
see [Known differences](known-differences.md).

## Timing

### `PAUSE` and `BEEP` durations are scaled by the compiler

This one is not the interpreter. **The compiler rewrites the number
before the interpreter ever sees it.** DRC multiplies every `PAUSE` and
`BEEP` duration by this target's own note length, 0.6, on the way into
the database: `PAUSE 100` in your source compiles to `PAUSE 60`, and
`BEEP 50 120` compiles with a duration of 30. The interpreter then waits
exactly the number of frames the database asks for, at 50 Hz.

The consequence is that a pause you authored as one second lasts about
0.6 of a second.

**Author against what you hear, not against the arithmetic.** One second
is `PAUSE 83` on this target - 83 scaled by 0.6 is 50 frames at 50 Hz.
`PAUSE 167` gives about two seconds. Duration tables in older DAAD or
MALUVA guides were written for other targets, so treat them as a
starting point and check the result by ear.

`XPLAY`'s generated notes are scaled the same way. See
[Audio](audio.md) for the rest of what the compiler does to a `BEEP`.

## Pictures and the screen

### `DISPLAY` works on the picture layer, not on text

`DISPLAY n` with a non-zero value clears the Layer 2 picture surface and
flips it into view. It does **not** clear text, because on this machine
text is not on the picture layer at all. The old DAAD idiom `DISPLAY @0`
- "clear the screen when it is dark" - therefore does not clear your
prose here. Use `CLS` for text and `DISPLAY` for pictures; they are two
different surfaces and each condact reaches one of them.

`DISPLAY 0` re-draws the current picture. It always does the work, even
if the same picture is already on screen, so it is not free - do not put
one inside a tight loop and expect it to cost nothing.

### `GFX` sub-commands 9 and 10 do nothing

These are the numbered palette store and recall. On this target a
picture carries its own palette and loads it as the picture loads, so
there is no numbered palette slot for them to write to or read from.
Both sub-commands are accepted and do nothing at all, so a game that
uses them still runs; it simply gets no palette change.

Sub 15 is a no-op for a different reason. On CPC and C64 it is
`XSPLITSCR`, a split-screen toggle; this target has no split-screen
mode, so 15 is accepted and does nothing here too. Worth stating
explicitly now that its neighbour, sub 16, installs a font - see
[Customising](customising.md).

The `GFX` sub-commands that *are* implemented here - the buffer copies
and swaps, the surface clears, video playback on 13 and 14, and font
installation on 16 - are listed in [Symbols](reference/symbols.md),
[Video](video.md) and [Customising](customising.md).

## Condacts

### A `DOALL` inside a `DOALL` stops with error 4

There is one `DOALL` at a time. If a sub-process called from inside a
`DOALL` starts its own, the game stops with runtime error 4 rather than
quietly producing the wrong answer.

Do not nest `DOALL` loops. The loud failure is the point: a nested
`DOALL` has no correct meaning here, and finding that out as an error on
screen is better than finding it out as an inventory that silently lost
half its objects.

### `MOUSE` 6 and 7 set the pointer hotspot

Despite the symbol names `DELTAXMS` and `DELTAYMS`, these two do not
report how far the mouse moved. They set the hotspot offset inside the
pointer bitmap - the pixel of your artwork that lands on the reported
coordinate. If your pointer is a cross, you probably want its hotspot at
5,5 rather than at the top-left corner.

All eight sub-commands, 0 to 7, are implemented. A pointer shape switch
(`MOUSE n 5`) does not move or reset the hotspot these two set - it
stays wherever you last put it. The full table is in
[Symbols](reference/symbols.md), and [Customising](customising.md)
covers supplying your own pointer artwork, base and numbered alike.

### `EXTERN` implements three vectors

`EXTERN n v` picks one of sixteen dispatch vectors - the mechanism MALUVA
used to bolt extra features onto older DAAD. Three of them do something
here:

- **Vector 3, `XMESSAGE`** - print external text held in `0.XMB`. It
  reads exactly like a message stored in the database: same token
  expansion, same word wrap, same More... paging. A missing or
  unreadable `0.XMB` prints nothing and the game carries on. In a
  version 3 database the native `XMES` opcode reaches the same text with
  no `EXTERN` involved; the vector stays for version 2 databases. See
  [Limits](reference/limits.md).
- **Vector 4, `XPART`** - switch the running game to another part. See
  [Multi-part games](multi-part-games.md).
- **Vector 7, `XUNDONE`** - clear the current action's done stamp, for a
  `SYNONYM`-style entry that should not count as a completed turn.

**Every other vector is a safe no-op.** The condact is consumed and play
continues. The rest of classic MALUVA - `XPICTURE`, `XSAVE`, `XLOAD`,
`XBEEP`, `XSPEED`, `XNEXTCLS`, `XNEXTRST` - is deprecated in the compiler
in favour of engine features this target covers natively:
`PICTURE`/`DISPLAY` for pictures, `SAVE`/`LOAD` for game state, `EXIT`
for a reset, and `SFX` for sound.

Two things are deliberately unavailable. The compiler's `-X`
(`dumpToXMB`) switch, which would route all of a game's text through
`0.XMB` rather than only the text you asked for by name, is not
implemented. And **do not hand-write `EXTERN n 3`** for anything else:
vector 3 has a three-byte encoding of its own, and the engine always
consumes the matching third byte whenever it sees that shape, so any
other use of a literal 3 there misaligns every condact after it.

### `AUTOG` searches here, then carried, then worn

`AUTOG` - the condact behind a `GET` entry that takes its object from
what the player typed rather than from a number in your source - looks
for that noun at the player's location first, then among carried
objects, then among worn ones, and takes the first it finds.

That order only shows when the same noun matches more than one object at
once. If your game can have a duplicate both carried and worn, the
carried one is the one `GET` resolves to here. jDAAD tries worn before
carried, so a game written against it can pick up the other object.
Where it matters, name the object explicitly rather than relying on the
search order.

### `END` confirms against SM31

`END` prints SM13 and reads a line. A reply beginning with SM31's first
character ends the session; anything else restarts the game. (`QUIT` is
the mirror image: it prints SM12 and confirms on SM30's first
character.)

Write SM30 as your "yes" word and SM31 as your "no" word, and both read
correctly. The prompt itself is SM13 either way; what differs is which
message the reply is tested against - jDAAD tests `END` against SM30
instead, so a game whose message table was written for it can act on the
wrong reply here. Check SM30 and SM31 when you bring one across.

### `RAMLOAD n` restores flags 0 to n inclusive

`RAMLOAD` with a flag argument restores object locations in full and
flags **0 to n inclusive** - that is, n + 1 flags. `RAMLOAD 10` restores
eleven flags, 0 through 10.

jDAAD stops one short, at 0 to n - 1. A game that leans on the partial
restore to protect a particular flag will find that flag restored here
and not there, or the other way round, with nothing on screen to say so.
Choose an argument that leaves an unused flag on the boundary and the
question stops mattering.

**One exception.** In a [multi-part game](multi-part-games.md), a
`RAMLOAD` whose snapshot was taken in a different part is always a full
restore - the argument is ignored entirely, and every flag comes back.
The partial restore only applies within one part.

## Text and messages

### `@` capitalises, and only in Spanish databases

`_` substitutes the referenced object's name into a message, in every
language. `@` is the capitalising form of the same escape and it exists
for **Spanish databases only**.

So in an English database `@` is an ordinary printable character: a
message containing `-@@-` prints `-@@-`. In a Spanish database, `@`
substitutes the name with its first letter uppercased and `_`
substitutes it unchanged.

If you are bringing in a game whose English messages relied on `@`
substituting, change those to `_`.

### Article stripping in substituted names

When an object's text is substituted into a message, a leading **"a "**,
**"an "**, **"some "** or **"the "** is removed - matched whatever the
case - and nothing else is. Any other first word survives: an object
text of "rusty sword" substitutes as "rusty sword", not "sword".

The stock system messages supply their own article ("You now have the
_."), so write your `/OTX` entries as "a lamp", "an axe", "some rope" or
"the key" and all four read correctly. An `/OTX` beginning with any
other word keeps that word, which is the point - a descriptive name
stays intact.

Leading spaces are not touched. The article has to be the literal start
of the text.

**Porting note.** jDAAD removes the first word whatever it is. A game
written against that will have object texts that only read correctly
when the first word is thrown away - "my wallet" gives "You now have the
my wallet." here. Rewrite those few texts without the possessive.

Listings are not affected at all. `LISTOBJ`, `LISTAT` and the inventory
print the object text whole, article included.

### A substituted name stops at the first "."

A substituted object name is truncated at the first full stop. An object
text of "a quaint lamp. It is unlit." reads as "quaint lamp" inside a
message and prints whole in a listing, so one `/OTX` entry can serve as
both a short name and a longer description.

## The parser

### A bare noun numbered below 40 acts as a verb

If the player types a noun on its own and gives no verb, DAAD moves the
noun into the verb slot when its vocabulary id is below 40. Ids 39 and
below convert; 40 and above do not.

**What to do with that:** any noun you number in the 20-39 band will act
as a command when it is typed bare. If you have a noun that must never
be a verb, number it 40 or above. Direction words and other words meant
to work when typed on their own belong below 40.

### `PARSE 1` and quoted text

`PARSE 1` re-parses the quoted section of the last order. Two separate
rules govern it, and it is worth knowing which is which:

- **Whether a quoted section exists** decides whether the sentence flags
  are refilled. `SAY HELLO`, with no quotes, leaves the current sentence
  untouched. `SAY ""`, with empty quotes, clears it.
- **What the quoted section contains** decides the condition, by the
  same "a verb or a noun was found" test `PARSE 0` uses. `SAY "PLUGH"`
  fails the condition, because it filled a verb. `SAY "FAST"` passes -
  an adverb on its own is not a sentence. `SAY "ZZZZ"` passes.

Words after the closing quote still parse into the normal sentence, and
convertible nouns are converted inside a quoted section exactly as they
are outside one.

## Flags the interpreter publishes

### Flags 29 and 62 describe this machine

- **Flag 29**, the graphics capability byte, reads **129**: bit 7
  because Layer 2 location graphics exist, bit 0 because the `MOUSE`
  condact is implemented. `HASAT GMODE` is therefore true here, so a
  period game that gates its picture drawing on `HASAT GMODE` does draw
  its pictures. Bit 0 is set whether or not a mouse is plugged in.
- **Flag 62**, the screen mode byte, reads **144**: bit 7 for "palette
  switching is available", bit 4 for "a native machine mode, not one of
  the original ST or PC values", and the low four bits naming the mode -
  0 here, for Layer 2 at 256x192 in 256 colours. Test the bit you care
  about rather than comparing the whole byte against a number; every
  machine puts a different value in it.

Both are written once when the game starts and are not rewritten if the
game switches Layer 2 mode later.

A save file made before these flags were published carries the old
values, so an old save restores flag 29 as 0 and takes the no-graphics
branch of `HASAT GMODE` until something rewrites it. Start a fresh game
to pick up the current values.

## Debug builds

### A `-D` build plays exactly like a normal one

Compiling with the debug flag writes a marker into the process tables
wherever you put a `DEBUG` line. NextDAAD steps over those markers and
carries on.

**This is the only DAAD interpreter where that works.** Everywhere else
the marker is read as `NEWTEXT`, which throws away the rest of a
multi-command order - so a debug build stops obeying `GET SWORD AND KILL
ORC` half way through, with nothing on screen to say why. Here it does
not, so you can leave `DEBUG` lines in your source while you work and
build with or without the flag without the game changing under you.

What a `DEBUG` line does not give you is a breakpoint. There is no
debugger attached to it on this target, so the line is simply inert. Do
not write one expecting the run to stop.
