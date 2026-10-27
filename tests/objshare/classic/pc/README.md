# OBJVERIF on the PC interpreter

Emulated, not hardware: DOSBox 0.74-3, debug build
(C:\Program Files (x86)\DOSBox-0.74-3\dosbox-74-3-debug.exe), headless,
DAAD-READY's ASSETS\PC\GAME\PCDAAD.EXE (VGA256) with PC.FNT as DAAD.FNT
(see `../README.md`). Trees: sd\LEGCPC\CTL and TEST (ndrc 0.4.0 at NDRC
commit 4b2f776). Run 2026-10-27.

Result: PASSED. All 37 steps equal the control (text and paging pauses);
every final and paged screen decodes to the same text once the random
prompt rows are removed; boot text identical.

## Method

    python -I ..\drive_pc.py run <scratch>\CTL ..\..\walk.txt ctl --work <scratch>\wctl
    python -I ..\drive_pc.py run <scratch>\TEST ..\..\walk.txt test --work <scratch>\wtest
    python -I ..\drive_pc.py compare test ctl results.md

The trees are run from scratch copies (diff-equal to sd\LEGCPC before and
after); each run copies GAME\ again into its work folder. One emulator at
a time, killed at the end of each run.

Headless: SDL_VIDEODRIVER=dummy and SDL_AUDIODRIVER=dummy in the
environment, and the process starts inside a Windows pseudo console
(CreatePseudoConsole), so no console window exists. The debug build's
PDCurses debugger UI needs a real console buffer: with CREATE_NO_WINDOW
initscr() fails ("LINES value must be >= 2") and DOSBox exits 8. The
driver checks for a visible window owned by the process on every poll and
kills it if one appears (none did). The conf is the staged dosbox.conf
with `output=surface`, `nosound=true`, `pcspeaker=false` and the
autoexec replaced by: mount the GAME copy as C:, `KBTSR`, `PCDAAD`.

DOSBox 0.74-3 has no AUTOTYPE command (DOSBox-X has); there is no
keyboard input from outside a window. Keys and screens go through
KBTSR.COM (`../pc_kbtsr.s`, assembled by the driver with mingw-w64
`as --32` and `objcopy -O binary`), a TSR on INT 16h. PCDAAD reads keys
only through INT 16h AH=1/AH=0 (ibmpc.pas:121-136), so a poll means the
game is waiting. Once per BIOS tick a poll opens CMD.TXT in the mounted
folder (4-digit sequence, op, data): op K queues (ASCII, scan code)
pairs that AH=1/AH=0 then return; op D writes A000:0000 (64000 bytes,
mode 13h) plus the 768-byte DAC to SCR.BIN. ACK.TXT gets the sequence
when the op is done and the key queue has drained. Commands are typed
lower case; ENTER is 0D/1C, SPACE 20/39.

Screen: a read is one D op, so it returns only while the game is polling
the keyboard; polled every 0.25 s until stable for about 1 s with the
'_' caret ending the last row. PCDAAD's More... pause prints nothing (no
SM32; ibmpc.pas:523-536), so a stable screen with no caret is a pause:
it is captured as a page and dismissed with SPACE (classic_leg's
"nocursor" path). Text is decoded from the bitmap (ink = any colour but
the commonest) in 8-pixel bands, vertical phase search, against
DAAD.FNT: the last 2304 bytes are 256 widths and 256 x 8 scanlines
(charset.pas:30-31), and WriteChar plots column j of a width-w glyph
from bit 8-j (ibmpc.pas:575-592), so each glyph paints all w columns.
Each band is matched by the cheapest exact cover with glyphs (unexplained
paper columns cost 50, unexplained ink 1000 and decode as '?'). Step
text, prompt trimming and pause handling are drive_zx48.py's
(`../classic_leg.py`). PNGs are rendered from SCR.BIN with its DAC.

A step PASSES when its decoded text and its pauses equal the control's.
"Screen memory identical" in `results.md` is the raw 64000-byte compare
(with DAC); it is "no" on 35 of 37 steps because the random SM2-SM5
prompt differs between the runs, not because of game text: the "Screen
text identical, prompts removed" column is "yes" on all 37.

## Results

`results.md` holds the per-step table. 37 steps, 0 FAIL. Pauses at
steps 2, 27, 29 and 37 in both builds (the 32-column window holds more
proportional text per row than on the ZX 48K, so steps 31 and 34 do not
page and 27 pages once). Both transcripts equal the ZX 48K transcripts
of the same build word for word with line wrap ignored (the ZX 48K
control equals jDAAD's). Object names print whole in the inventory,
EXAMINE and through '_' in GET, DROP, WEAR and REMOVE; PAIRS, EMPTY,
TEST, the duplicate locations and the final LOOK and I match the
control.

## Files

- `test/`, `ctl/` - `step00_boot.png`, `stepNN.png`, `stepNN_pageK.png`
  (pauses), `transcript.txt`, `transcript.jsonl` (text, pages, decoded
  screens, screen SHA-1s)
- `results.md` - per-step PASS/FAIL table
