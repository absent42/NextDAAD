# Flags and objects

## System flags 0-63

The interpreter owns these. Read them freely; write only the ones marked
writable. STARTER.DSF defines a symbol for most of them; use the symbols.

| Flag | STARTER symbol | Meaning |
|---|---|---|
| 0 | fDark | Non-zero = dark. Writable. Object 0 present makes a dark room visible |
| 1 | fObjectsCarried | Objects carried (not worn). Kept by GET/DROP/PLACE/CREATE; SWAP does not touch it |
| 2-24 | | Not used by the interpreter but not reliably free either: STARTER uses 28, older tools used 20-21. Prefer 64-255 for game data |
| 25-27 | | Used by the V3 second-object machinery. Not free |
| 28 | fDarkF | STARTER's own "it is dark right now" scratch flag |
| 29 | fGFlags | Bit 7 graphics available (`HASAT GMODE`), bit 0 mouse present |
| 30 | fScore | Score. The interpreter never touches it; the game keeps it |
| 31, 32 | fTurns, fTurnsHi | Turn count, low and high byte. STARTER's process 1 increments it |
| 33 | fVerb | Verb of the current sentence |
| 34 | fNoun | First noun |
| 35 | fAdject1 | First adjective |
| 36 | fAdverb | Adverb |
| 37 | fMaxCarr | Maximum objects carried. Starts at 0 on NextDAAD: set it in the init process (STARTER uses 4) |
| 38 | fPlayer | Player location. Writable via GOTO |
| 39, 40 | | Used by V3. Not free |
| 41 | fStream | Input stream |
| 42 | fPrompt | Prompt system message (0 = random pick of SM2-5) |
| 43 | fPrep | Preposition |
| 44 | fNoun2 | Second noun |
| 45 | fAdject2 | Second adjective |
| 46, 47 | fCPronounNoun, fCPronounAdject | What IT refers to |
| 48 | fTimeout | Input timeout in seconds (set by TIME) |
| 49 | fTimeoutFlags | Timeout control bits; bit 7 = a timeout just happened (`HASAT TIMEOUT`) |
| 50 | fDoallObjNo | Location the current DOALL is searching (255 already turned into the player's location); kept after the loop. The object on each pass is in flag 51. Do not carry a value in it across PROCESS |
| 51 | fRefObject | The current (referenced) object: what `_` prints and HASAT tests |
| 52 | fStrength | Maximum carried plus worn weight. Starts at 0 on NextDAAD: set it in init (STARTER uses 10) |
| 53 | fObjFlags | Bit 7 = LISTOBJ/LISTAT printed something; bit 6 = list on one line; V3 bits: 5 unknown word after the verb, 4 preposition before the first noun, 1 moves the HASAT bank, 0 DOALL found nothing |
| 54-59 | fRefObjLoc .. fRefObjAttr2 | Current object's location, weight, container (128), wearable (128), attribute bytes |
| 60, 61 | fInkeyKey1/2 | Key code after INKEY / GETKEY |
| 62 | fScreenMode | Screen mode (144 on NextDAAD) |
| 63 | fCurrentWindow | Active window |
| 64-255 | | Yours. Minus 224-251 if the kit's extern collection is loaded (it is, by default) |

A clean scheme: give each game flag a `#define` (`#define fDoorOpen 64`),
number upward from 64, and treat 224-255 as taken.

## Special location values

| Value | Symbol | Meaning |
|---|---|---|
| 252 | NOT_CREATED, `_` | Object does not exist yet |
| 253 | WORN | On the player |
| 254 | CARRIED | In the player's hands |
| 255 | HERE | The player's room, accepted by PLACE, PUTO, AUTOT, ISAT, ISNOTAT, LISTAT and DOALL only. Everywhere else write `@38` |

Locations run 0-251. Location 0 is where the game starts; STARTER uses it
as the intro screen and moves to 1 in the init process.

## The object record

Each object has: starting location, weight (0-63), container flag,
wearable flag, 16 attribute bits, a noun and an adjective. Objects with the
same noun are told apart by adjective, and if the player gives none, by
where they are (here, then carried, then worn for GET).

### Containers

A container is an object whose `c` column is `Y`. Its contents live at the
location whose number equals the object number, so a container that is
object 3 needs location 3 to exist in `/LTX` and `/CON` (give it an empty
text and no exits). `PUTIN obj 3`, `TAKEOUT obj 3`, `AUTOP 3`, `AUTOT 3` and
`LISTAT 3` all use that number. A zero-weight container makes its contents
weigh nothing.

### Attributes

The sixteen `Y`/`_` columns are free per-object bits. Make the object
current (`SETCO n`, `WHATO`, or any GET/DROP/AUTO action) and test
`HASAT n` / `HASNAT n` with n 0-15; change them with `SETAT n 1` (set),
`SETAT n 0` (clear), `SETAT n 2` (toggle). Left to right in the `/OBJ`
line the columns are bits 7 6 5 4 3 2 1 0 15 14 13 12 11 10 9 8, so bit 0
is the eighth column.

### Object 0

Object 0 is the light. With flag 0 set, the room is dark unless object 0 is
present (carried, worn or in the room). Put the lamp, torch or candle at
object 0 and set flag 0 in dark locations.

## System messages used by the interpreter

STARTER.DSF ships all of 0-62 in English. The ones a game most often
changes:

| SM | Used for |
|---|---|
| 0 | It is too dark to see |
| 1 | "I can also see:" before the object list |
| 2-5 | Prompts (flag 42 = 0 picks one at random) |
| 6 | Sentence not understood |
| 7 | Cannot go that way |
| 8 | Cannot do that |
| 9, 10 | Inventory headers (carried, worn) |
| 12 | "Are you sure?" for QUIT |
| 13 | "Play again?" for END |
| 15 | "OK." printed by OK |
| 16 | Press any key (ANYKEY) |
| 30, 31 | One upper-case letter each: yes and no |
| 32 | "More..." |
| 33 | The input prompt line |
| 35 | Timeout message |
| 36 | "I now have the _." after GET |
| 44, 45, 52 | PUTIN / TAKEOUT sentence starts; keep their trailing space |
| 53 | Nothing there (LISTAT) |
