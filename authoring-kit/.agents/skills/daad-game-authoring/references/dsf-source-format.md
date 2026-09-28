# DSF source format

The exact shape of a DAAD source file as the kit's compiler reads it. Section
order is enforced; text encoding is ISO-8859-1, not UTF-8 (plain English is
unaffected).

## Section order

```
#define ...            ; symbols, before /CTL
/CTL                   ; obsolete; one line holding _
/VOC                   ; vocabulary
/STX                   ; system messages 0-62 (the interpreter uses all of them)
/MTX                   ; messages (may be empty; inline MESSAGE "..." is easier)
/OTX                   ; object texts, one per object
/LTX                   ; location texts, one per location
/CON                   ; connections, one block per location
/OBJ                   ; object definitions, one per object
/PRO 0 ... /PRO n      ; process tables
/END                   ; mandatory, in the main file (not an #include)
```

Comments: `;` to end of line. A string token runs from the first quote to the
last quote on the line, so never put a quote inside a comment on a line that
also holds a string.

## Vocabulary

One word per line: `WORD value type`.

```
GET     20      verb
TAKE    20      verb        ; same value + same type = synonym
LAMP    100     noun
BRASS   100     adjective
IT      255     pronoun
AND     2       conjugation ; the keyword really is "conjugation"
IN      1       preposition
QUICK   3       adverb
```

- Types: `verb`, `noun`, `adjective`, `adverb`, `preposition`, `pronoun`,
  `conjugation`.
- Only the first five letters count (`REMOVE` is `REMOV`). Two words that
  share five letters are the same word.
- A word may be defined once, whatever its type. `LIGHT` cannot be both a
  verb and a noun: pick one, and use `SYNONYM` or a second word for the other.
- Values 1-254; 255 is the null word `_`.
- Value ranges with meaning (see the parser section below):
  verbs under 14 are directions; nouns under 40 act as verbs when typed on
  their own; nouns under 50 are proper nouns and do not set the pronoun.

## Text tables: /STX /MTX /OTX /LTX

```
/LTX
/0 "Intro text shown once.#n#n"
/1 "Jetty#nA weathered jetty. The tower stands to the north."
```

- Numbers consecutive from 0, at most 255 per table.
- One line per text; `#n` for a line break.
- Single or double quotes; a quote of the other kind inside is fine.
- `/OTX` count must equal `/OBJ` count; `/LTX` count must equal `/CON` count.
- The compiler also allocates numbers for inline `MESSAGE "..."`, `MES "..."`
  and `SYSMESS "..."` strings and de-duplicates identical text. 765 texts in
  total across MTX, STX, LTX and inline strings.

### Escape codes inside any text

| Code | Effect |
|---|---|
| `_` | Name of the referenced object (flag 51), article stripped, cut at the first `.` |
| `#n` | Newline (`\n` also works; no other backslash escapes) |
| `#s` | Space, useful at the end of a message |
| `#b` | Clear the current window (not a space) |
| `#k` | Wait for a key mid-text; `#k#b` = wait then clear |
| `#f` | Non-breaking space |
| `#g` / `#t` | Switch to the upper (graphic) charset / back |
| `##` | Literal `#` |

`@` capitalises the object name in Spanish databases only; in English it
prints as `@`.

### Object text convention

Write every object text as an article plus the name and nothing after it:
`"a brass lamp"`, `"some rope"`, `"the rusty key"`. System messages print
`_` after stripping a leading "a ", "an ", "some " or "the " (any case),
and they add their own full stop, so `"a brass lamp."` comes out as
"I now have the brass lamp..". Text after the first `.` is dropped in
substitution but shown in listings, so `"a lamp. It is unlit."` lists in
full and substitutes as "lamp"; use that only when you want the longer
listing text.

## Connections

```
/CON
/0                       ; every location needs a block, even with no exits
/1
N       2
UP      lLampRoom        ; symbols are fine
/2
S       1
```

The direction must be a `/VOC` verb or noun. Locations run 0-251.

## Objects

```
/OBJ
;obj  starts   weight  c w  attribute bits (16 columns)          noun   adj
/0    CARRIED  1       _ _  _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _   LAMP   _
/1    3        2       Y _  _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _   BOX    _
/2    WORN     1       _ Y  _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _   COAT   _
```

| Field | Values |
|---|---|
| starts | location number or symbol, `CARRIED` (254), `WORN` (253), `NOT_CREATED` or `_` (252) |
| weight | 0-63; a zero-weight container makes its contents weightless |
| c | `Y` = container. Its contents live at the location whose number equals the object number, so reserve that location |
| w | `Y` = wearable; an object that starts `WORN` must be wearable |
| 16 columns | `Y` or `_`; tested with `HASAT n` once the object is current. Left to right the columns are HASAT bits 7 6 5 4 3 2 1 0 15 14 13 12 11 10 9 8 |
| noun, adj | vocabulary words or `_`. An object with noun `_` can never be named by the player |

Object 0 is the light source: when flag 0 is non-zero, the room is dark
unless object 0 is present.

## Processes

```
/PRO 5
> GET    LAMP   AT 1
                MESSAGE "It is bolted to the wall."
                DONE

> GET    _      AUTOG
                DONE

$retry                              ; local label, target for SKIP $retry
> UNLOC  DOOR
> OPEN   DOOR   CARRIED oKey        ; two headers share one body
                SET fDoorOpen
                MESSAGE "The door swings open."
                DONE
```

- Header `> VERB NOUN`; `_` matches anything.
- Condacts follow in any layout: on the header line, one per line, or mixed.
- `/PRO n` may use a symbol. Numbers should be contiguous; a repeated number
  concatenates with a warning.
- Labels are local to the process and may be forward references.

## Preprocessor

| Directive | Notes |
|---|---|
| `#define sym value` | Case-sensitive; define before use. Expressions in quotes: `#define fTurnsHi "fTurns+1"` |
| `#ifdef "SYM"` / `#ifndef "SYM"` / `#else` / `#endif` | The label must be quoted. `NEXTDAAD` and `V3` are predefined by the kit build |
| `#include file.dsf` | Unquoted, one level only; `/END` stays in the main file |
| `#echo "text"` | Prints at compile time |
| `#classic` | Refused by the kit |

Built-in symbols: `CARRIED`, `WORN`, `NOT_CREATED`, `HERE`, `COLS`, `ROWS`,
`NUM_OBJECTS`, `NUM_LOCATIONS`, `NUM_CARRIED`, `NUM_WORN`, `LAST_OBJECT`,
`LAST_LOCATION`, `V3`, `NEXTDAAD`, the `SFX` names `PLAYSFX`..`PLAYFLIL`
and the `MOUSE` names `RESETMS`..`DELTAYMS`. Every vocabulary word also
exists as `_VOC_WORD`.

## The parser

A logical sentence is `(adverb) verb (adjective noun) (preposition) (adjective noun)`
in any order. Unknown words such as THE are skipped. Conjunctions and
punctuation split the input line into sentences; a sentence with no verb
reuses the previous one, so `GET LAMP AND KEY` works. Up to 125 characters
of input. The result lands in flags 33 verb, 34 noun, 35 adjective,
36 adverb, 43 preposition, 44 noun 2, 45 adjective 2. `PARSE 0` fetches the
next sentence from the line; when none is left (or on timeout) it runs the
condact that follows it, which is how the standard game loop reaches its
"I did not understand" process.

## Compiler errors you will meet

Format: `line:col:file: message.` The compiler stops at the first error.

| Message | Meaning |
|---|---|
| `Word "X" already defined` | Same five letters used twice in `/VOC` |
| `"x" is not a valid vocabulary word type` | Usually `conjunction`; write `conjugation` |
| `Verb not found in vocabulary` / `Noun not found in vocabulary` | The entry header names a word missing from `/VOC`, or one defined with the wrong type |
| `Message/Locations/Object numbers must be consecutive` | A gap in a text table |
| `Connections for location #n missing` | `/CON` needs a block for every `/LTX` entry |
| `Definition for object #n missing` | `/OBJ` needs a line for every `/OTX` entry |
| `Noun not defined` / `Adjective not defined` | The `/OBJ` noun column names a word missing from `/VOC` |
| `Unknown condact` | Misspelt condact, or a PAW/Quill action that DAAD lacks |
| `Invalid parameter value "x" for condact Y` | Out-of-range number; object, location or message does not exist |
| `Invalid percent value, must be in the 1-99 range` | `CHANCE 0` or `CHANCE 100` |
| `Label "X" is too far from SKIP call` | `SKIP` reaches at most 128 entries |
| `"X" is not defined` | A symbol used before its `#define`, or a typo |
| `Input file has no /END section` | Add `/END` at the end of the main file |

`-no-semantic` is not a fix: it lets bad numbers through to fail at runtime.
