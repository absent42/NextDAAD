# OBJVERIF - compressed object texts and shared duplicates

Verification fixture for ndrc 0.4.0 `-auto-tokens`, which compresses
object texts and emits each duplicate text once (duplicate lookup entries
point at one copy). The DDB format is unchanged; this fixture checks that
interpreters read both correctly.

- `OBJVERIF.DSF` - fixture. English, BLANK_EN shape, plain DAAD condacts,
  7-bit ASCII. Compiles for NEXTDAAD, ZX 48K, CPC, MSX, PC VGA256, HTML.
- `walk.txt` - command script, one command per line (37 turns).
- `assert_stim.py` - byte assertions on the test and control DDBs.

## Content

Objects (0-4 and 7 carried, 5-6 worn; window 32x10 so More... fires
inside the inventory list):

| # | Text | Noun |
|---|------|------|
| 0 | a lamp | LAMP |
| 1 | the key | KEY |
| 2 | some coins | COINS |
| 3 | a map of the winding river valley | MAP |
| 4 | a scroll sealed by the old king | SCROL |
| 5 | a woollen cloak with a frayed hem | CLOAK (wearable) |
| 6 | a silver ring from the old king | RING (wearable) |
| 7 | a lamp | LANTE |

Messages 2-16 repeat the object phrases so the selector picks them. MTX 2
("You examine _ closely.") runs on every EXAMINE; SM36-SM39 run on
GET/DROP/WEAR/REMOVE; MTX 3 carries '@' (EXAMINE LANTERN).

Duplicate pairs: OTX 0/7, STX 63/64, MTX 23/24, LTX 1/2, empty MTX 25/26.

Verbs: I (carried and worn), EXAMINE <noun>, GET, DROP, WEAR, REMOVE,
LOOK, N/S between locations 1 and 2 (identical texts; PRO 3 prints the
location number after the text), PAIRS (both members of the STX, MTX and
LTX pairs), EMPTY (marker, MES of both empty messages, marker), TEST (the phrase
messages 12-16).

## Build

From a scratch copy, the control from a second name so no .tok lookup
applies (delete any .tok a run writes):

    copy OBJVERIF.DSF CTL.DSF
    ndrc NEXTDAAD EN OBJVERIF.DSF test.ddb -auto-tokens
    ndrc NEXTDAAD EN CTL.DSF ctl.ddb
    python -I assert_stim.py test.ddb ctl.ddb

Classic legs use the same commands with `ZX 48K`, `CPC`, `MSX` or
`PC VGA256` in place of `NEXTDAAD`.

## Assertions

`assert_stim.py test.ddb ctl.ddb [--base N]` exits 0 only when all pass.
The base address is derived from the end-address word at 0x20 minus the
file length unless `--base` is given.

Test DDB:
- an object text holds a token reference
- an object text starts with a reference
- an object text ends with a reference (last byte before 0x0A)
- an object text is a single reference
- a 12-byte token (the selector maximum) lands in an object text
- each duplicate pair shares one lookup word
- every text in all four tables expands to the control's text

Control DDB: no object text holds a reference, and no fixture pair
shares a lookup word.

## Results (ndrc 0.4.0, 2026-10-27)

All six targets PASS, control clean.

| Target | test.ddb | ctl.ddb |
|--------|---------:|--------:|
| NEXTDAAD | 2228 | 2679 |
| ZX 48K, CPC, MSX | 2236 | 2679 |
| PC VGA256, HTML | 2308 | 2772 |

Object texts in the test build (NEXTDAAD; classic targets identical shape,
token numbers shifted by the '_'/'@' exclusion):
- 0 and 7: single reference ("a lamp"), one shared copy
- 2: single reference ("some coins")
- 1: three references ("th", "e ", "key") - starts and ends with one
- 3: holds the 12-byte "winding rive"; ends with "r valley"
- 5: holds the 12-byte "a frayed hem", which ends the text
- 4, 6: end with "old king"

## Pre-flight (Windows)

jDAAD (tools\DAAD-READY\ASSETS\HTML jdaad.js, tests\parser\jleg.js):
HTML target test and control builds, work folder holding daad.jddb
(the compiler's .jddb), jdaad.js, images.js, extern.js. jleg.js takes a
JSON array, so convert walk.txt first:

    python -c "import json;print(json.dumps([l.strip() for l in open('walk.txt') if l.strip()]))" > walk.json
    node tests\parser\jleg.js <workdir> walk.json out.jsonl

Result: the two out.jsonl files are byte-identical over all 37 turns
(text, flags, object locations). Object names print whole in the
inventory, EXAMINE and SM36-SM39; the article strips ("You examine lamp",
"I've dropped the coins"); both members of every pair print; EMPTY prints
only its markers. More... fires inside the worn list of both I turns
(seen with a pause counter in a scratch copy of jleg.js, which does not
record pager pauses itself).
jDAAD prints '@' literally.

ADP (ddb.exe built from a copy of tools\ADP-main with the mingw-w64 gcc
in C:\ProgramData\mingw64\mingw64\bin on PATH,
`mingw32-make -f Makefile-win64 PREFIX= UPX=0 out/win64/ddb.exe`):
PC VGA256 test and control builds, headless scripted mode:

    set SDL_VIDEODRIVER=dummy
    set SDL_AUDIODRIVER=dummy
    ddb -o transcript.txt -i walk_adp.txt test OBJVERIF.DDB

walk_adp.txt is walk.txt plus `@key` and `@exit` lines (the final I ends
on a More... pause). Result: transcripts byte-identical, no warnings;
ADP substitutes '@' ("Lamp is here").

No difference between test and control on either tool: no fixture,
compiler or tool finding.
