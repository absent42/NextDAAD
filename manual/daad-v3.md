# DAAD V3

The kit compiles your game as a **DAAD version 3** database. The
interpreter loads both version 2 and version 3, so nothing forces you
either way, but version 3 is what `BUILD.BAT` produces unless you change
it - and a game written for version 2 changes behaviour in three places
when you rebuild it here.

If you are starting a new game, there is nothing to do: write it, build
it, and the V3 features below are simply available.

## What version 3 gives you

- **Second-parameter indirection** - `LET 100 @101` and the same form on
  other condacts, where the second parameter is taken from a flag rather
  than written literally.
- **`GETKEY`** as a keyword of its own, waiting for a keypress.
- **`XMES`** as a native 3-byte opcode rather than a 4-byte `EXTERN`
  call with a MALUVA vector behind it. See
  [Limits](reference/limits.md) for what XMESSAGE and XMES cost.
- **The flag 53 attribute bits**, below.

## Moving an existing version 2 game to V3

Three things change, none of them produces a compile error, and all
three misbehave quietly. Grep your source for all three before you trust
a V3 build of an older game.

**1. `SYNONYM` stops marking the entry DONE.**

Grep: `SYNONYM`. If any of them is followed by an `ISDONE` that expects
the synonym itself to have counted as an action, that entry stops
firing. Nothing errors; the entry just stops behaving. This is the one
real migration hazard - it is silent and it is a logic change.

**2. `PAUSE 0` stops meaning "wait 256 frames".**

Grep: `PAUSE 0`. Under V3 it is GETKEY, so the game waits for a keypress
instead of about five seconds. Replace it with `PAUSE 255`, or whatever
duration you actually meant, if you wanted the wait.

**3. `HASAT` / `HASNAT` / `SETAT` start honouring flag 53 bit 1.**

Grep for any write to flag 53 - `LET 53`, `SET 53`, `PLUS 53`, or a
`COPYFF`/`COPYBF` with 53 as the destination. Under V3, bit 1 of flag 53
moves the attribute flag bank from flag 59 to flag 91, so a game using
flag 53's low bits as scratch will find its attribute reads looking
somewhere else entirely.

There is a second half to this one: under V3 the interpreter itself also
writes bits 0, 4 and 5 of flag 53, which it does not touch under V2. A
game that reads flag 53 as a whole value - `EQ 53 n` rather than `HASAT`
- will see different numbers even if it never writes the flag.

The starter game that ships with the kit passes all three checks, and
compiles byte-identically in either dialect apart from the version byte
in its header.

## Flag 53 bit 1 and the alternative attribute bank

Under version 3, bit 1 of flag 53 moves the attribute flag bank from
flag 59 to flag 91. `HASAT`, `HASNAT` and `SETAT` all honour it, so you
can set the bit, write with `SETAT`, and read the same attributes back
with `HASAT`.

The bank switch is gated on the database being version 3. Under version
2 the interpreter never looks at flag 53 bit 1, so a version 2 game is
free to use flag 53 as scratch.

## The version 3 opcodes

Opcodes 120 (`XMES`), 122 (`INDIR`) and 124 (`SETAT`) are live only when
the database header says version 3. In a version 2 database they raise
runtime error 5. The compiler will not emit them into a version 2
database in the first place, so ordinary authoring never reaches that
error - it matters only if you are producing DDBs by some other route.

## Compiling version 2 instead

Remove `-v3` from the ndrc line in `lib\ddb.bat`. Both the main game and
every `PART<n>\` compile through that one line, so this covers every
part too.

**Every part the same dialect.** A
[multi-part game](multi-part-games.md) must compile all its parts to the
same version, because a part switch reloads a header while the flags
carry across.
