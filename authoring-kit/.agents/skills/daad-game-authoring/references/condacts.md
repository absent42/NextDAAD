# Condacts

Every condact the kit's compiler accepts, grouped by what it does. C is a
condition: when it is false the rest of the entry is abandoned and the table
scan moves to the next matching entry. A is an action. A* is an action that
can refuse: on failure it prints a system message, then does `NEWTEXT` and
`DONE`, so nothing after it runs and the player sees the refusal.

Notation: `obj` object number, `loc` location, `loc+` location or `CARRIED`
(254), `WORN` (253), `NOT_CREATED` (252) or `HERE` (255, accepted only where
noted), `flag` and `val` 0-255, `word` a vocabulary word, `msg` a message
number or `"string"`.

## Player location

| Condact | Type | Meaning |
|---|---|---|
| `AT loc` | C | Player is at loc |
| `NOTAT loc` | C | Player is not at loc |
| `ATGT loc` | C | Player location is greater than loc |
| `ATLT loc` | C | Player location is less than loc |
| `GOTO loc` | A | Move the player (sets flag 38); follow with `RESTART` or `DESC @38` to show it |
| `MOVE flag` | A, can fail | Apply the typed direction to the location held in flag via the `/CON` table. Fails the entry when there is no such exit |

## Where objects are

| Condact | Type | Meaning |
|---|---|---|
| `PRESENT obj` | C | Object is carried, worn or in the room |
| `ABSENT obj` | C | Not present |
| `CARRIED obj` | C | Carried |
| `NOTCARR obj` | C | Not carried |
| `WORN obj` | C | Worn |
| `NOTWORN obj` | C | Not worn |
| `ISAT obj loc+` | C | Object is at loc+ (HERE allowed) |
| `ISNOTAT obj loc+` | C | Object is not at loc+ |

## Moving objects

| Condact | Type | Meaning |
|---|---|---|
| `GET obj` | A* | Pick up; refuses if absent, too heavy (flag 52) or too many (flag 37) |
| `DROP obj` | A* | Drop here |
| `WEAR obj` | A* | Wear a carried wearable |
| `REMOVE obj` | A* | Take off a worn object |
| `CREATE obj` | A | Put the object in the current room |
| `DESTROY obj` | A | Send the object to 252 (not created) |
| `PLACE obj loc+` | A | Move the object to loc+ (HERE allowed) |
| `SWAP o1 o2` | A | Exchange the two objects' positions |
| `PUTO loc+` | A | Move the current object (flag 51) to loc+ (HERE allowed) |
| `PUTIN obj loc` | A* | Put a carried object into container loc |
| `TAKEOUT obj loc` | A* | Take an object out of container loc |
| `DROPALL` | A | Drop everything carried and worn |
| `AUTOG` | A* | GET the object the player named; searches here, carried, worn |
| `AUTOD` | A* | DROP the named object |
| `AUTOW` | A* | WEAR the named object |
| `AUTOR` | A* | REMOVE the named object |
| `AUTOP loc` | A* | PUTIN the named object into container loc |
| `AUTOT loc` | A* | TAKEOUT the named object from container loc (HERE allowed) |
| `WHATO` | A | Make the object the player named the current object |
| `SETCO obj` | A | Make obj the current object (flags 51, 54-59) |
| `COPYOO o1 o2` | A | Move o2 to wherever o1 is |
| `COPYOF obj flag` | A | Object's location into flag |
| `COPYFO flag obj` | A | Move object to the location held in flag |
| `WEIGH obj flag` | A | Weight of obj including contents into flag |
| `WEIGHT flag` | A | Total carried plus worn weight into flag |
| `RESET` | A | Every object back to its starting position |
| `ABILITY objs weight` | A | Set flags 37 and 52 |

The AUTO* family, `GET`, `DROP`, `WEAR`, `REMOVE`, `WHATO`, `SETCO` and
each pass of `DOALL` set the current object, which is what `_` prints and `HASAT` tests. `CREATE`,
`DESTROY` and `PLACE` do not.

## Flags

| Condact | Type | Meaning |
|---|---|---|
| `ZERO flag` | C | flag = 0 |
| `NOTZERO flag` | C | flag is not 0 |
| `EQ flag val` | C | flag = val |
| `NOTEQ flag val` | C | flag is not val |
| `GT flag val` | C | flag > val |
| `LT flag val` | C | flag < val |
| `SAME f1 f2` | C | Two flags equal |
| `NOTSAME f1 f2` | C | Two flags differ |
| `BIGGER f1 f2` | C | f1 > f2 |
| `SMALLER f1 f2` | C | f1 < f2 |
| `SET flag` | A | flag = 255 |
| `CLEAR flag` | A | flag = 0 |
| `LET flag val` | A | flag = val |
| `PLUS flag val` | A | Add, stops at 255 |
| `MINUS flag val` | A | Subtract, stops at 0 |
| `ADD f1 f2` | A | f2 = f2 + f1 |
| `SUB f1 f2` | A | f2 = f2 - f1 |
| `COPYFF f1 f2` | A | f2 = f1 |
| `COPYBF f1 f2` | A | f1 = f2 (reversed, for indirection) |
| `RANDOM flag` | A | flag = 1-100 |
| `CHANCE pct` | C | True pct percent of the time; pct is 1-99 |

Indirection: `@flag` in a parameter uses the flag's value, so `MESSAGE @100`
prints the message whose number is in flag 100 and `DESC @38` describes the
current room. Under the kit's V3 dialect both parameters may be indirected:
`LET 100 @101`.

## The typed sentence

| Condact | Type | Meaning |
|---|---|---|
| `ADJECT1 word` | C | First noun's adjective is word (`_` = none) |
| `ADVERB word` | C | Adverb is word |
| `PREP word` | C | Preposition is word |
| `NOUN2 word` | C | Second noun is word |
| `ADJECT2 word` | C | Second noun's adjective is word |
| `SYNONYM verb noun` | A | Rewrite the sentence's verb and noun; `_` keeps the existing one. Later entries then match the new words |
| `PARSE 0` | A | Fetch the next sentence from the input line; when there is none, run the next condact |
| `PARSE 1` | A | Parse quoted speech, for talking to characters |
| `NEWTEXT` | A | Throw away the rest of the input line |

## Done state and attributes

| Condact | Type | Meaning |
|---|---|---|
| `ISDONE` | C | The last table called did something (any action except `NOTDONE`) |
| `ISNDONE` | C | The last table called did nothing |
| `HASAT n` | C | Attribute bit n of the current object is set (0-15); other values test bits of flags 59 down to 28 |
| `HASNAT n` | C | Bit n is clear |
| `SETAT n op` | A | Set (1), clear (0) or toggle (2) attribute bit n |

Handy symbol values for `HASAT`: `WEARABLE` 23, `CONTAINER` 31, `LISTED` 55,
`TIMEOUT` 87 (a timeout happened), `GMODE` 247 (graphics available).

## Output

| Condact | Type | Meaning |
|---|---|---|
| `MES msg` | A | Print, no newline |
| `MESSAGE msg` | A | Print, then newline |
| `SYSMESS n` | A | Print system message n |
| `DESC loc` | A | Print a location text (no newline); write `DESC @38` for "here" |
| `XMES "t"` / `XMESSAGE "t"` | A | Same as MES / MESSAGE but the text lives in `0.XMB`, outside the 64K database |
| `PRINT flag` | A | Print a flag as a decimal number |
| `DPRINT flag` | A | Print the 16-bit number in flag and flag+1 |
| `NEWLINE` | A | Newline |
| `SPACE` | A | Space |
| `LISTOBJ` | A | List objects here after system message 1; prints nothing when empty |
| `LISTAT loc+` | A | List objects at loc+ (HERE allowed); system message 53 when empty |

## Windows and screen

| Condact | Type | Meaning |
|---|---|---|
| `WINDOW n` | A | Select window 0-7 |
| `WINAT row col` | A | Position the window's top-left |
| `WINSIZE rows cols` | A | Size the window, clipped to the screen |
| `CENTRE` | A | Centre the window horizontally |
| `CLS` | A | Clear the current window |
| `PRINTAT row col` | A | Move the print position |
| `TAB col` | A | Move to a column |
| `SAVEAT` / `BACKAT` | A | Save / restore the print position |
| `INK c` / `PAPER c` / `BORDER c` | A | Colours 0-255 |
| `MODE n` | A | 1 = upper charset, 2 = no "More..." prompt |
| `PICTURE n` | A, can fail | Load picture n; the entry stops if there is no such picture |
| `DISPLAY n` | A | 0 = draw the loaded picture, non-zero = blank the picture area |

## Input and timing

| Condact | Type | Meaning |
|---|---|---|
| `INKEY` | C | A key is down; its code is in flag 60 |
| `GETKEY` | A | Wait for a key (same as `PAUSE 0` in V3) |
| `ANYKEY` | A | Print system message 16 and wait for a key |
| `PAUSE n` | A | Wait; the kit's compiler scales it, so `PAUSE 83` is about one second |
| `QUIT` | C | Ask system message 12; true when the player answers with the first letter of SM30 |
| `TIME secs opt` | A | Input timeout in seconds; `TIME 0 0` turns it off |
| `INPUT stream opt` | A | Choose the input window and options |
| `SAVE 0` / `LOAD 0` | A | Save or load a game (asks for a name); follow with `RESTART` |
| `RAMSAVE` / `RAMLOAD n` | A | In-memory save / restore flags 0-n; follow with `RESTART` |

## Flow

| Condact | Effect |
|---|---|
| `DONE` | Leave the table; the command counts as handled |
| `NOTDONE` | Leave the table; the command counts as not handled |
| `OK` | Print system message 15 then DONE |
| `REDO` | Restart the current table from its first entry |
| `RESTART` | Abandon everything and restart process 0 (redraws the room) |
| `PROCESS n` | Call table n and come back (10 levels deep at most) |
| `SKIP n` / `SKIP $label` | Jump n entries forward or back (up to 128), or to a label in the same process |
| `DOALL loc+` | Run the rest of the table once for each object at loc+ (HERE allowed), each in turn becoming the referenced object (flag 51); flag 50 holds the location; cannot be nested; when nothing is there it does NEWTEXT and NOTDONE |
| `END` | Ask system message 13 "play again?"; restarts, or quits |
| `EXIT 0` | Leave to the loader; any other value restarts the game |

Anything written after `DONE`, `NOTDONE`, `OK`, `SKIP`, `RESTART` or `REDO`
in the same entry is discarded by the compiler.

## Sound, graphics, externs

| Condact | Meaning |
|---|---|
| `BEEP dur tone` | Tone: tone 48-238 and even |
| `SFX n s` | Music, samples, effects, video; s picks the sub-command |
| `GFX n s` | Buffers, palette, fonts, sprites, video, cursor; s picks the sub-command |
| `MOUSE flag s` | Pointer control; s picks the sub-command |
| `EXTERN p fn` | Call machine-code function fn; may fail the entry |
| `CALL lsb msb` | Call an address inside `GAME.XBN` |

The sub-command tables are in nextdaad-features.md.

## Runtime errors

`RUNTIME ERROR - E<n>` on a magenta bar: 0 invalid object, 1 invalid
location (typically `DESC 255` or a `GOTO` past the last location),
3 too many nested `PROCESS` calls, 4 nested `DOALL`, 6 call to a process
that does not exist, 7 invalid message, 8 invalid picture.
