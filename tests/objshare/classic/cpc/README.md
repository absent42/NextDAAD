# OBJVERIF on the Amstrad CPC interpreter

Emulated, not hardware: ZEsarUX 13.0 (`--machine CPC6128`, headless
`--vo null --ao null`, `--enable-dsk --dsk-file <dsk>`, ZRCP port
10779), DAAD-READY's ASSETS\CPC\DCPCIEF3.BIN packaged by MCRF onto
BLANK.DSK (see `../README.md`). Images: sd\LEGCCPC\OBJCTL.DSK and
OBJTEST.DSK (ndrc 0.4.0 at NDRC commit 4b2f776). Run 2026-10-27.

Result: PASSED. All 37 steps equal the control (text and More...
pauses); every final and paged screen decodes to the same text once the
random prompt rows are removed; boot screen identical.

## Method

    python -I ..\drive_cpc.py run <scratch>\OBJCTL.DSK ..\..\walk.txt ctl
    python -I ..\drive_cpc.py run <scratch>\OBJTEST.DSK ..\..\walk.txt test
    python -I ..\drive_cpc.py compare test ctl results.md

The DSKs are run from scratch copies (cmp-equal to sd\LEGCCPC);
ZEsarUX's DSK persistent writes are off by default. One emulator at a
time, killed at the end of each run.

Boot: CPC 6128 BASIC 1.1 to `Ready` (ZEsarUX `get-ocr`), then RUN"DAAD.
ZEsarUX's CPC key mapping drops '"' (and every other punctuation key),
so `runxdaad` is typed, the x in BASIC's edit buffer at &AC8A is
overwritten with &22 over ZRCP (checked by reading the buffer back) and
ENTER sent; AMSDOS loads DAAD.BIN from the disc. Walk commands are
letters and spaces only, typed lower case with `send-keys-string`, 150
ms per key; ENTER and SPACE with `send-keys-ascii`.

Screen: `set-memory-zone 0` (128K RAM), `read-memory 49152 16384`
(&C000), polled every 0.25 s until stable for about 1 s with the line
editor caret showing; a settled screen ending in "More..." is captured as
a page and dismissed with SPACE. Text is decoded from the mode 1 bitmap
(line address &C000 + (y mod 8)*&800 + (y div 8)*80, 2 bits per pixel,
ink = any pen but the background) in 8x8 cells, 40 columns, vertical
phase search, against AD8x8.CHR, the font MCRF packaged
(`../cscreen.py`). AD8x8.CHR draws '1' and 'l' with the same glyph; a run
of that glyph next to a letter is read as 'l', otherwise '1' ("Location
number 1", "valley"). The caret is a solid block and decodes as '_'.
Step text, prompt trimming and More... handling are drive_zx48.py's
(`../classic_leg.py`). PNGs are ZEsarUX `save-screen` BMPs converted to
PNG (border included).

A step PASSES when its decoded text and its More... pauses equal the
control's. "Screen memory identical" in `results.md` is the raw 16K
compare; it is "no" on 36 of 37 steps because the random SM2-SM5 prompt
picked per turn differs between the two runs (timing-seeded), not
because of game text: the "Screen text identical, prompts removed"
column is "yes" on all 37.

The control transcript equals jDAAD's control transcript (HTML build of
the same source, tests/parser/jleg.js) on all 37 steps once prompt and
input rows are removed, and equals the ZX 48K control transcript line for
line (same 32-column window wrap). The test transcript equals the ZX 48K
test transcript.

## Results

`results.md` holds the per-step table. 37 steps, 0 FAIL. More... pauses
at steps 2, 27 (two), 29, 31, 34 and 37 in both builds, as on the ZX
48K. Object names print whole in the inventory, EXAMINE and through '_'
in GET, DROP, WEAR and REMOVE; PAIRS, EMPTY, TEST, the duplicate
locations and the final LOOK and I match the control.

## Files

- `test/`, `ctl/` - `step00_boot.png`, `stepNN.png`, `stepNN_pageK.png`
  (More... pages), `transcript.txt`, `transcript.jsonl` (text, pages,
  decoded screens, screen SHA-1s)
- `results.md` - per-step PASS/FAIL table
