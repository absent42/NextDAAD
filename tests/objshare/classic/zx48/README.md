# OBJVERIF on the ZX Spectrum 48K interpreter

Emulated, not hardware: ZEsarUX 13.0 (`--machine 48k`, headless
`--vo null --ao null`, ZRCP port 10778), DAAD-READY's
ASSETS\ZX\48K\DS48IE3.BIN packaged by daadmaker /48 (see
`../README.md`). Run 2026-10-27, ndrc 0.4.0 at NDRC commit 4b2f776
(classic article-strip rule).

Result: PASSED. All 37 steps equal the control (text and More...
pauses); every final screen PNG is byte-identical to the control's; boot
screen identical.

History: the first run (2026-10-27, NDRC b6611c2) FAILED at step 3
(EXAMINE LAMP), 23 of 37 steps different, all '_' object-name
substitutions (EXAMINE via MTX 2, SM36-SM39): the name printed empty
for objects 0, 1, 2, 4, 6, 7 and without its first word for object 5.
The interpreter's article skip scans the stored bytes for the first
literal space, so a space inside a token reference is not seen and the
skip runs on to the next literal space or the end of the text. 4b2f776
keeps the first word and the space run after it literal on classic
targets; this run replaces that evidence.

## Method

    python -I ..\drive_zx48.py run OBJTEST.TAP ..\..\walk.txt test
    python -I ..\drive_zx48.py run OBJCTL.TAP ..\..\walk.txt ctl
    python -I ..\drive_zx48.py compare test ctl results.md

One emulator at a time, smartloaded over ZRCP, killed at the end of each
run. Per walk.txt line: the command is typed (`send-keys-string`, 150 ms
per key), the screen captured, Enter sent, then `read-memory 16384 6912`
polled every 0.25 s until stable for about 1 s with the line-editor
cursor showing. A settled screen ending in "More..." is captured as a
page (`stepNN_pageK.png`) and dismissed with SPACE.

Screen text is decoded from the bitmap against the AD8x6.CHR font the
TAP was built with (6-pixel cells, 42 columns, vertical phase search;
tests/parser/zscreen.py), not the ROM font: the interpreter draws its
own 6-pixel glyphs, which do not sit on the ULA's 8-pixel cells. A
step's text is the new rows since the typed command (scroll matching;
between two More... pages every row is new), with the random input
prompt (SM2-SM5) and the input row trimmed. A step PASSES when its text
and its More... pauses equal the control's.

"PNG identical" in `results.md` is the byte compare of the two final
screens; it also differs when earlier, already failed output is still
on screen, or when the random prompt differs, so the text column is the
verdict.

The control transcript matches jDAAD's control transcript (HTML build of
the same source, tests/parser/jleg.js) on all 37 steps once the prompt
lines are removed, and is unchanged from the first run.

## Results

`results.md` holds the full per-step table (control text, test text).
37 steps, 0 FAIL. More... pauses at steps 2, 27 (two), 29, 31, 34 and
37 in both builds. Object names print whole in the inventory (steps 2,
37), in EXAMINE ("You examine lamp closely.", "You examine woollen
cloak with a / frayed hem closely.") and through '_' in GET, DROP, WEAR
and REMOVE ("I've dropped the lamp.", "I'm now wearing the woollen /
cloak with a frayed hem."). PAIRS, EMPTY, TEST, the duplicate locations
and the final LOOK and I match the control.

## Files

- `test/`, `ctl/` - `step00_boot.png`, `stepNN.png` (screen after step
  NN), `stepNN_pageK.png` (More... pages), `transcript.txt` (decoded
  text per step), `transcript.jsonl` (text, pages, decoded screens)
- `results.md` - per-step PASS/FAIL table
