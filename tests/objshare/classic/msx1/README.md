# OBJVERIF on the MSX1 interpreter

Emulated, not hardware: openMSX 0.15.0 (tools\DAAD-READY\TOOLS\openmsx,
`-machine Philips_NMS_8250` as MSX1.BAT, `-control stdio`, renderer
`none` and sound driver `null` from a settings file passed with
`-setting`), DAAD-READY's ASSETS\MSX\MSX1\DMSXIEF3.BIN packaged on
MSX1.DSK with MSXDAAD.COM, DAAD.MDG (AD8x6.CHR spliced in) and DAAD.DDB
(see `../README.md`). Images: sd\LEGCMSX\OBJCTL.DSK and OBJTEST.DSK
(ndrc 0.4.0 at NDRC commit 4b2f776). Run 2026-10-27.

Result: PASSED. All 37 steps equal the control (text and More...
pauses); VRAM is byte-identical to the control's on every final and
paged screen and at boot.

ZEsarUX was tried first: its MSX1 machine emulates cartridges and tape
only, no disk drive, so the DSK cannot boot there. The NMS 8250 is an
MSX2; it is the machine DAAD-READY launches for its MSX1 target and the
only real machine whose system ROMs the bundled openMSX carries (the
rest are C-BIOS).

## Method

    python -I ..\drive_msx1.py run <scratch>\OBJCTL.DSK ..\..\walk.txt ctl --work <scratch>
    python -I ..\drive_msx1.py run <scratch>\OBJTEST.DSK ..\..\walk.txt test --work <scratch>
    python -I ..\drive_msx1.py compare test ctl results.md

openMSX writes to a disk image in place, so each run copies the DSK to
the scratch folder first (the sd\LEGCMSX images were cmp-checked
unchanged afterwards). One emulator at a time, killed at the end of each
run.

Boot: `set power on`; MSX-DOS boots from the disc and AUTOEXEC.BAT runs
MSXDAAD.COM, which loads DAAD.Z80, DAAD.MDG and DAAD.DDB. The driver
waits for graphic II (VDP R#0 M3) and takes the table bases from the VDP
registers (R#2 6, R#3 255, R#4 3: names &1800, patterns &0000, colours
&2000). Commands are typed lower case with the Tcl `type` command, ENTER
as `type "\r"`, SPACE as `type " "`.

Screen: `debug read_block VRAM 0 16384`, hex-encoded in Tcl, polled
every 0.25 s until stable for about 1 s with the caret showing; a
settled screen ending in "More..." is captured as a page and dismissed
with SPACE. Text is decoded from the graphic II bitmap (name table plus
the three pattern banks) in 6-pixel cells, 42 columns, vertical phase
search, against AD8x6.CHR, the font spliced into DAAD.MDG
(`../cscreen.py`). Step text, prompt trimming and More... handling are
drive_zx48.py's (`../classic_leg.py`). PNGs are rendered from VRAM with
the colour table and the TMS9918 palette (an MSX2 palette change would
not show).

A step PASSES when its decoded text and its More... pauses equal the
control's.

The control transcript equals jDAAD's control transcript (HTML build of
the same source, tests/parser/jleg.js) on all 37 steps once prompt and
input rows are removed, and equals the ZX 48K control transcript line for
line. The test transcript equals the ZX 48K test transcript.

## Results

`results.md` holds the per-step table. 37 steps, 0 FAIL. More... pauses
at steps 2, 27 (two), 29, 31, 34 and 37 in both builds, as on the ZX
48K. Object names print whole in the inventory, EXAMINE and through '_'
in GET, DROP, WEAR and REMOVE; PAIRS, EMPTY, TEST, the duplicate
locations and the final LOOK and I match the control.

## Files

- `test/`, `ctl/` - `step00_boot.png`, `stepNN.png`, `stepNN_pageK.png`
  (More... pages), `transcript.txt`, `transcript.jsonl` (text, pages,
  decoded screens, VRAM SHA-1s)
- `results.md` - per-step PASS/FAIL table
