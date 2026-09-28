# Pitfalls

Mistakes that compile fine and then misbehave, or that fail the build in a
way the message does not explain. Each is the symptom, then the rule.

## Two responses print for one command

**Symptom.** "You unlock the door." followed by "I can't do that."

**Rule.** The entry fell through. End every response entry with `DONE`
(or `OK`, `NOTDONE`, `RESTART`). Process 1 only treats the command as handled
when process 5 reports done.

## The player cannot leave the room

**Symptom.** A direction that should work just re-prompts, or prints
"I can't go in that direction" although the exit is in `/CON`.

**Rule.** An entry for that direction in process 5 ran an action (`SET`,
`LET`, a message) and so marked the command handled, and process 1 never
reached `MOVE`. An entry that prepares something and should still let the
engine move the player ends with `NOTDONE`; an entry that moves the player
itself does `GOTO`, `CLS`, `RESTART`.

## The generic entry swallows the special case

**Symptom.** `GET LAMP` in the one room where it should be refused just
picks it up.

**Rule.** Order matters: the special `> GET LAMP AT lRoom ...` entry must
sit above `> GET _ AUTOG`. Same for `EXAMI _` catch-alls, which go last.

## The player can carry nothing

**Symptom.** Every GET says "I can't carry any more things."

**Rule.** Flags 37 and 52 start at 0 on NextDAAD. Set them in the init
process (`LET fMaxCarr 4`, `LET fStrength 10`, or `ABILITY 4 10`).
STARTER.DSF already does; keep those lines when you replace its init.

## A word is rejected as already defined

**Symptom.** `Word "LIGHT" already defined`.

**Rule.** One word, one type. `LIGHT` cannot be both the verb and the noun.
Give the noun a different word (`LAMP`), or make the verb `LIGHT` and use
`SYNONYM` to fold other phrasings onto it. Also five letters only: `BOOKS`
and `BOOKSHELF` are the same word.

## A command works typed alone but not in a sentence

**Symptom.** `LAMP` alone runs the examine entry; `TAKE LAMP` does nothing.

**Rule.** Nouns numbered under 40 are conversion nouns: typed alone they
become the verb. Give real objects nouns 50 and up (STARTER starts at 100),
and keep 40-49 for nouns that should never act as commands but must not set
IT. Under 50 also means "proper noun": IT will not refer to it.

## A specific entry never fires

**Symptom.** `> CLIMB TOWER` below `> U _` never runs, although the player
typed exactly that.

**Rule.** Tables match by word number, not spelling. `CLIMB` and `U` with
the same number are the same verb, and `> U _` matches any noun, so it
takes the sentence first. Put the entry with the noun above the bare one.

## QUIT falls through to "I can't do that"

**Symptom.** Answering N to "Are you sure?" prints SM8.

**Rule.** `QUIT` is a condition. Keep STARTER's pair:
`> Q _ QUIT / END` then `> Q _ DONE`.

## SAVE or LOAD leaves the screen wrong

**Rule.** Follow `SAVE`, `LOAD`, `RAMSAVE` and `RAMLOAD` with `CLS` and
`RESTART` so the room is redrawn from the restored state.

## The object name prints wrong

**Symptom.** "I now have the a lamp." or "I now have the lamp. It is heavy."

**Rule.** Start object texts with an article ("a lamp") so `_` strips it,
and put any extra description after a full stop; substitution cuts at the
first `.`, listings show the whole text.

## `_` prints the wrong object

**Symptom.** After `CREATE 5` a message with `_` names some earlier object.

**Rule.** `CREATE`, `DESTROY` and `PLACE` do not set the current object.
`SETCO 5` first. GET, DROP, WHATO and the AUTO actions do set it.

## HASAT tests the wrong thing

**Rule.** `HASAT 0-15` tests the current object (flag 51). Make the object
current first. Values above 15 test bits of system flags, which is how
`HASAT TIMEOUT` (87) works.

## Runtime error 1 on a room

**Symptom.** `RUNTIME ERROR - E1` when describing.

**Rule.** `DESC 255` is not "here" on NextDAAD; write `DESC @38`. A `GOTO`
past the last location does the same.

## Text that does not fit

**Symptoms.** `GAME.DDB is N bytes, over the 65535 limit`, or
`Too many messages ... is 765`.

**Rule.** Move long descriptive text to `XMESSAGE "..."` (it lives in
`0.XMB`, another 64K). The per-table limit is 255 entries; inline
`MESSAGE "..."` strings count toward the 765 total.

## The timer never fires

**Rule.** Timeouts are flags 48 and 49, set by `TIME secs opt`. When the
timeout happens `PARSE 0` fails into process 2, where `HASAT TIMEOUT`
tells it from a bad sentence. `TIME 0 0` turns it off.

## A comment breaks a string

**Symptom.** A message prints with `; ...` inside it, or the compiler
reports the next line.

**Rule.** The string token is from the first quote to the last quote on the
line. No quotes in a comment on a line that holds a string.

## `#b` in a message does not print a space

**Rule.** `#b` clears the window. `#s` is the space.

## CHANCE 100 does not compile

**Rule.** `CHANCE` takes 1-99. For "always" drop the condition.

## Music keeps playing after RESTART or death

**Rule.** `RESTART`, `QUIT` and the play-again path leave sound running.
Stop it yourself with `SFX 0 8` (music) and `SFX 0 5` (effects) where the
story needs silence. `EXIT 0` silences everything.

## A picture, sprite or font silently does nothing

**Rule.** Missing assets are silent at runtime. Check the number in the file
name and that the converted file exists in `RELEASE\` (for a picture,
`NNN.NX2` or `NNN.NXI`). `PICTURE n` for a missing picture fails the entry,
so anything after it in that entry is skipped too.

## GFX or SFX does something unexpected

**Rule.** The sub-command is the second parameter. `GFX 1 13` plays video 1;
`GFX 13 1` copies a buffer. Check the tables in nextdaad-features.md.

## PAUSE is too short

**Rule.** The compiler scales `PAUSE` and `BEEP` by 0.6. One second is
`PAUSE 83`. `PAUSE 0` waits for a key under V3.

## An extern fails and the entry stops

**Rule.** `EXTERN` can be a condition. Follow every condition-style extern
(hints `EXTERN n 50`, realtime `EXTERN 0 66`, playername 20/22/23) with a
fallthrough entry that handles the refusal, exactly as STARTER's `TIME` and
`HINT` entries do.

## A flag changes by itself

**Rule.** Flags 25-27, 39-40 and 224-251 are not free. Keep game data in
64-223, or 64-255 only if the game ships without the extern collection.

## The build refuses to start

**Symptom.** `set GAME in CONFIG.BAT`.

**Rule.** More than one `.DSF` in the kit root. Either keep one, or set
`GAME=name` in `CONFIG.BAT`.
