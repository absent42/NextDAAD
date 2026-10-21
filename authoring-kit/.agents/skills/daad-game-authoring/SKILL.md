---
name: daad-game-authoring
description: "Reference and workflow for writing a DAAD text adventure with the NextDAAD authoring kit: DSF source (vocabulary, texts, connections, objects, process tables), the condact set and system flags, the standard process layout, idiomatic patterns (doors, darkness, timers, characters, containers, score), NextDAAD extras (pictures, colours, music, samples, video, fonts, sprites, mouse, externs, hints, multi-part games) and the kit's build and run cycle. Use whenever someone is writing, extending, converting or debugging a DAAD game in this kit - a new game, a room, a puzzle, a verb, an object, a message, a sound, a picture, a build error or wrong in-game behaviour - even if they do not say DAAD, DSF or condact."
---

# DAAD game authoring for NextDAAD

A game in this kit is a game folder, `<GAME>\`, holding one `<GAME>.DSF`
text file plus optional assets in `IMAGES\`, `AUDIO\` and `VIDEO\` inside
it, and its own settings in `<GAME>\<GAME>.CFG`. `SET GAME=<GAME>` in
`CONFIG.local.BAT` selects it. The build compiles the DSF to `GAME.DDB`
and stages everything in `RELEASE\<GAME>\` (`<GAME>.NEX` plus `DATA\`),
ready for an SD card or the emulator. This skill is the language and the kit in one place; the manual
in `docs\` is the authority for anything it does not settle.

## Start from a copy of STARTER\, not from a blank page

`STARTER\STARTER.DSF` is a complete, building game skeleton: the
vocabulary every game needs, all 63 system messages, the standard process
tables and working examples of pictures, music, samples, video, externs and
hints. Every kit update replaces `STARTER\`, so never edit it. Copy the
whole folder to `MYGAME\`, rename `STARTER.DSF` and `STARTER.CFG` in the
copy to `MYGAME.DSF` and `MYGAME.CFG`, put `SET GAME=MYGAME` in
`CONFIG.local.BAT` (create it from `CONFIG.local.BAT.sample`), and add
rooms, objects and entries to `MYGAME\MYGAME.DSF`. With more than one
game folder the build needs that `GAME` line.

Processes 0, 1 and 2 are the engine's loop: leave them as they are. A game
lives in process 5 (commands), process 4 (things that happen every turn),
process 3 (extra text after a room description) and the tail of process 6
(setup). Details in `references/process-patterns.md`.

## Workflow

1. **Design first, in plain words.** List the locations and their exits,
   the objects with where they start, and each puzzle as "player does X, in
   state Y, result Z". Vocabulary and flags follow from that list. A puzzle
   that needs a state is one flag; number game flags from 64 with a
   `#define` each.
2. **Write the sections in order**: `/VOC`, then the texts (`/LTX` and
   `/OTX` must have exactly as many entries as `/CON` and `/OBJ`), then
   `/CON`, `/OBJ`, then the process entries. The compiler enforces the
   section order and the one-to-one counts. Syntax in
   `references/dsf-source-format.md`.
3. **Build after every change that touches structure.** Run `BUILD.BAT`
   (Windows) or `./build.sh` (Linux), or the compiler alone from inside
   the game folder when only the DSF changed:

       ..\lib\ndrc.exe nextdaad EN MYGAME.DSF ..\RELEASE\MYGAME\DATA\GAME.DDB -v3 -auto-tokens

   The first error names the line. `references/dsf-source-format.md` ends
   with the messages you will meet and what each means.
4. **Play it.** `RUN.BAT` / `./run.sh` launches the emulator on `RELEASE\<GAME>\`.
   Walk every exit, try every puzzle in the wrong state and the right one,
   and try each verb with no noun. Doubled messages and "I can't do that"
   after a real response are fall-through bugs (`references/pitfalls.md`).
5. **Add media last.** Pictures, music and effects are file-naming
   conventions plus one condact each; `references/nextdaad-features.md`
   has the names, formats and sub-command tables. A game is playable with
   none of them.

## Rules that save a debugging session

- **End every response entry with `DONE`.** An entry without a terminator
  falls through and later entries fire too. Specific entries go above
  generic ones (`> GET LAMP ...` above `> GET _ AUTOG`). Any action at all
  marks the command as handled, so an entry that only prepares something
  and must still let the engine move the player ends with `NOTDONE`.
- **One word, one type, five letters.** `/VOC` rejects a word defined twice
  in any type, and only the first five letters count. Nouns for real objects
  start at 50 (STARTER uses 100): nouns under 40 act as verbs when typed
  alone, nouns under 50 never set IT.
- **Flags 0-63 belong to the engine, 224-251 to the shipped externs.** Game
  data goes in 64-223. Flags 37 and 52 (carry limits) start at 0 on this
  interpreter; the init process must set them.
- **`DESC @38`, never `DESC 255`.** 255 means "here" only in `PLACE`,
  `PUTO` and `AUTOT`.
- **The current object is set by GET, DROP, WHATO, SETCO and the AUTO
  actions, not by CREATE, DESTROY or PLACE.** `_` in a message and `HASAT`
  both read it.
- **Sub-commands are the second parameter.** `GFX n s`, `SFX n s`,
  `MOUSE n s`: s picks what happens, n is its argument.
- **Object texts are "a brass lamp": article, name, no full stop.** The
  engine strips the article and supplies the sentence around `_`, so
  "a brass lamp." prints as "I now have the brass lamp..".
- **`PAUSE 83` is one second.** The compiler scales durations by 0.6.

## Quick reference

| Need | Write |
|---|---|
| Is the player here | `AT loc` / `NOTAT loc` |
| Object here, carried, worn | `PRESENT o`, `CARRIED o`, `WORN o` |
| Flag tests | `ZERO f`, `NOTZERO f`, `EQ f v`, `GT f v`, `LT f v` |
| Set flags | `SET f` (255), `CLEAR f` (0), `LET f v`, `PLUS f v`, `MINUS f v` |
| Move objects | `CREATE o`, `DESTROY o`, `PLACE o loc`, `SWAP o1 o2` |
| Move the player | `GOTO loc` then `RESTART` (redraws) |
| Print | `MESSAGE "text"` (newline), `MES "text"` (none), `PRINT f` |
| Finish an entry | `DONE`, `NOTDONE`, `OK` |
| Random | `CHANCE 1-99` |
| Picture n | `PICTURE n` then `DISPLAY 0` (STARTER's process 0 does it) |
| Music n once / looped / stop | `SFX n 6` / `SFX n 7` / `SFX 0 8` |
| Sample or effect n | `SFX n 1` |
| Video n | `GFX n 13` |
| Colours | `INK`, `PAPER`, `BORDER` 0-255; 227 is transparent |
| Win / die | `END` |

Full tables: `references/condacts.md`, `references/flags-and-objects.md`.

## Reference files

Load the one the work needs.

- `references/dsf-source-format.md` - every section's syntax, escape codes,
  the object record, the preprocessor, the parser, compiler error messages.
- `references/process-patterns.md` - the standard tables and worked entries:
  doors, examine, darkness, timers, characters, containers, score, endings,
  conversation, sub-tables.
- `references/condacts.md` - all condacts by category with conditions and
  actions marked, runtime error codes.
- `references/flags-and-objects.md` - system flags 0-63, special locations,
  containers, attributes, object 0, the system messages a game changes.
- `references/nextdaad-features.md` - colours, pictures and window geometry,
  GFX / SFX / MOUSE sub-command tables, audio file naming, video, fonts,
  sprites, externs and hints, XMESSAGE, multi-part games, differences from
  other DAAD interpreters.
- `references/kit-workflow.md` - game folders and where files go, BUILD /
  RUN / CLEAN, `CONFIG.BAT` / `<GAME>.CFG` / `CONFIG.local.BAT`, the
  compile line, build and runtime error messages.
- `references/pitfalls.md` - symptoms and the rule behind each.

The manual: `docs\index.html` in the kit root. For an extern of your own,
the `xbn-extern-authoring` skill beside this one.
