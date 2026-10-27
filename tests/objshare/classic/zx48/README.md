# OBJVERIF on the ZX Spectrum 48K interpreter

Emulated, not hardware: ZEsarUX 13.0 (`--machine 48k`, headless
`--vo null --ao null`, ZRCP port 10778), DAAD-READY's
ASSETS\ZX\48K\DS48IE3.BIN packaged by daadmaker /48 (see
`../README.md`). Run 2026-10-27, ndrc 0.4.0.

Result: FAILED. First failing step 3 (EXAMINE LAMP). 23 of 37 steps
differ from the control; boot screen identical.

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
lines are removed. A second pair of runs gave the same 23 failing steps.

## Results

`results.md` holds the full per-step table (control text, test text).

| Steps | Result | What differs |
|-------|--------|--------------|
| 1-2 (LOOK, I) | PASS | - |
| 3-5, 7, 9, 10 (EXAMINE lamp, key, coins, scroll, ring, lantern) | FAIL | "You examine  closely." (name empty) |
| 6 (EXAMINE MAP) | PASS | - |
| 8 (EXAMINE CLOAK) | FAIL | "You examine cloak with a frayed hem closely." (first word "woollen" lost) |
| 11-16, 19-22, 25-26, 30, 35 (GET/DROP/WEAR/REMOVE of objects 0, 1, 2, 4, 6, 7) | FAIL | "I've dropped the .", "I now have the .", "I've removed the .", "I'm now wearing the ." |
| 17-18 (DROP/GET MAP) | PASS | - |
| 23-24 (REMOVE/WEAR CLOAK) | FAIL | "the cloak with a frayed hem" (first word lost) |
| 27 (PAIRS) | PASS | both SM, MTX and location pair members print |
| 28 (EMPTY) | PASS | markers only, nothing between |
| 29 (TEST) | PASS | - |
| 31-34, 36 (LOOK, NORTH, LOOK, SOUTH, LOOK) | PASS | duplicate locations 1 and 2 both print |
| 37 (I) | PASS | final inventory clean, no corruption |

Inventory listing (LISTAT, steps 2 and 37) prints every compressed
object text whole, including the single-reference texts 0, 2 and 7 and
the More... pause inside the list. Only the '_' article skip loses
text: it appears to look for the first literal space byte in the
stored text, so a space inside a token reference is skipped over (see
`../README.md`).

## Files

- `test/`, `ctl/` - `step00_boot.png`, `stepNN.png` (screen after step
  NN), `stepNN_pageK.png` (More... pages), `transcript.txt` (decoded
  text per step), `transcript.jsonl` (text, pages, decoded screens)
- `results.md` - per-step PASS/FAIL table
