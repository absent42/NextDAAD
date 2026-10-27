# OBJVERIF classic interpreter legs

OBJVERIF (`../OBJVERIF.DSF`, `../walk.txt`) on the original DAAD
interpreters that DAAD-READY packages: ZX Spectrum 48K, Amstrad CPC, MSX1
and PC. Each target gets a test build (ndrc 0.4.0 `-auto-tokens`:
compressed object texts, shared duplicate lookup words) and a control
build (same source copied to `CTL.DSF`, no `-auto-tokens`).

- `drive_zx48.py` - ZX 48K driver (ZEsarUX 13 over ZRCP, headless)
- `drive_cpc.py` - CPC driver (ZEsarUX 13 CPC 6128 over ZRCP, headless)
- `drive_msx1.py` - MSX1 driver (openMSX 0.15 `-control stdio`, renderer none)
- `drive_pc.py` - PC driver (DOSBox 0.74-3 debug build, SDL dummy drivers,
  pseudo console; `pc_kbtsr.s` INT 16h TSR feeds keys and dumps mode 13h)
- `classic_leg.py`, `cscreen.py`, `omsx.py` - shared walk loop and
  compare, CPC/MSX screen decoders, openMSX control client
- `zx48/`, `cpc/`, `msx1/`, `pc/` - evidence, see each folder's README.md

## Legs (2026-10-27, ndrc 0.4.0 at NDRC commit 4b2f776)

Every row is emulated, not hardware.

| Leg | Interpreter | Packaged | Run | Result |
|-----|-------------|----------|-----|--------|
| ZX 48K | DS48IE3.BIN (ASSETS\ZX\48K) | yes, TAP | scripted, ZEsarUX 13 | PASSED 2026-10-27, 37 of 37 steps equal the control; emulated, not hardware |
| CPC | DCPCIEF3.BIN | yes, DSK | scripted, ZEsarUX 13 (CPC 6128) | PASSED 2026-10-27, 37 of 37 steps equal the control; emulated, not hardware |
| MSX1 | DMSXIEF3.BIN | yes, DSK | scripted, openMSX 0.15 (Philips NMS 8250, headless) | PASSED 2026-10-27, 37 of 37 steps equal the control; emulated, not hardware |
| PC | PCDAAD.EXE (VGA256) | yes, DOSBox tree | scripted, DOSBox 0.74-3 (debug build, headless) | PASSED 2026-10-27, 37 of 37 steps equal the control; emulated, not hardware |

CPC and MSX1 ran the sd\LEGCCPC and sd\LEGCMSX images unchanged; their
control transcripts equal jDAAD's and the ZX 48K control's, and their test
transcripts equal the ZX 48K test's. MSX1 is not on ZEsarUX because its
MSX1 machine has no disk drive. PC ran the sd\LEGCPC trees unchanged on
DOSBox 0.74-3 (no AUTOTYPE there either; keys and screen dumps go through
a TSR on INT 16h, see pc/README.md); its transcripts equal the ZX 48K
ones word for word with wrap ignored, and PCDAAD's silent More... pauses
fall at steps 2, 27, 29 and 37 in both builds.

History: the first ZX 48K run (2026-10-27, NDRC b6611c2, before the
classic article-strip rule) FAILED at step 3 (EXAMINE LAMP), 23 of 37
steps different, all in '_' substitution of an object name: the name
printed empty ("You examine  closely.", "I've dropped the .") or without
its first word ("cloak with a frayed hem"). The original Z80 '_' printer
scans the stored bytes for the first literal space, so a space inside a
token reference is not seen. Since 4b2f776 ndrc keeps, on every target
except NEXTDAAD, the first word of each object text and the space run
after it literal, leaves a text with no space uncompressed, and uses no
token containing '.' in object texts. The CPC, MSX1 and PC images were
re-staged from 4b2f776.

## Compile and assert

Flags follow the DAAD-READY BATs (`DRF ... -v3`, ZX48.BAT adds
`-force-normal-messages`; DRB target arguments from ZX48.BAT:58,
CPC.BAT:59, MSX1.BAT:64, PC.BAT:82):

    copy OBJVERIF.DSF CTL.DSF
    ndrc ZX 48K EN OBJVERIF.DSF test.ddb -force-normal-messages -v3 -auto-tokens
    ndrc ZX 48K EN CTL.DSF ctl.ddb -force-normal-messages -v3
    ndrc CPC EN OBJVERIF.DSF test.ddb -v3 -auto-tokens
    ndrc CPC EN CTL.DSF ctl.ddb -v3
    ndrc MSX EN OBJVERIF.DSF test.ddb -v3 -auto-tokens
    ndrc MSX EN CTL.DSF ctl.ddb -v3
    ndrc PC VGA256 EN OBJVERIF.DSF test.ddb -v3 -auto-tokens
    ndrc PC VGA256 EN CTL.DSF ctl.ddb -v3
    python -I ..\assert_stim.py test.ddb ctl.ddb

assert_stim.py runs in classic mode on these builds (machine id in the
high nibble of header byte 1 is not 0x0C): per object text, the first
stored byte is literal, no reference precedes the end of the space run
after the first word, a text with no space holds no reference, and no
referenced token contains '.'. These replace the NEXTDAAD-only "starts
with a reference" and "is a single reference" checks, which the rule
makes impossible.

| Target | Base | test.ddb | ctl.ddb | assert_stim.py |
|--------|-----:|---------:|--------:|----------------|
| ZX 48K | 0x8400 | 2240 | 2679 | PASS, control clean, rc 0 |
| CPC | 0x2880 | 2240 | 2679 | PASS, control clean, rc 0 |
| MSX | 0x0100 | 2240 | 2679 | PASS, control clean, rc 0 |
| PC VGA256 | 0x0000 | 2320 | 2772 | PASS, control clean, rc 0 |

All four report the same object texts and token references; every
object text keeps references after its first word:

    0: a [64]   1: the [5]   2: some [86]   3: a m[54][12][1][14][15]
    4: a [55]r[48][35][83][1][21]   5: a wo[48]en [75][77]
    6: a silv[65]r[34][28]r[72][1][21]   7: a [64]
    [1] ' the '  [5] 'key'  [14] 'winding rive' (12)  [64] 'lamp'
    [75] 'cloak with a' (12)  [77] ' frayed hem'  [86] 'coins'
    shared lookup groups: sysmess [11 14 17-22 34] [48 51] [63 64],
    messages [0 25 26] [23 24], locations [1 2], objects [0 7]
    23 checks OK (1 object-text, 8 article-strip, ends-with, 12-byte
    token, 5 sharing, expansion, 6 control)

Every object text in the fixture has a space, so the no-space case is
not exercised; no object-text token contains '.'. The control DDBs are
byte-identical to the b6611c2 builds.

## Packaging

DAAD-READY pieces copied to a scratch tree (ASSETS\ZX, CPC, MSX, PC,
CHARSET; TOOLS\DRC daadmaker.exe, mcrf.exe, pager48k.php; TOOLS\CPCDiskXP,
dsktool, DD); commands run from its root with GAME=OBJTEST / OBJCTL,
English, default fonts, no images, sounds or XMB.

ZX 48K (ZX48.BAT:84, 102-115):

    mkdir IMAGES\ZX & cd IMAGES\ZX
    tools\DAAD-READY\PHP\php.exe ..\..\TOOLS\DRC\pager48k.php ..\..\%GAME%.DDB
    cd ..\..
    copy ASSETS\ZX\DAAD.SDG
    move IMAGES\ZX\INDEX.BIN . & move IMAGES\ZX\PAGE0.TMP .
    TOOLS\DRC\daadmaker.exe %GAME%.TAP ASSETS\ZX\48K\DS48IE3.BIN %GAME%.DDB ASSETS\CHARSET\AD8x6.CHR INDEX.BIN DAAD.SDG /48

INDEX.BIN = FF FF 00 00 00 C0 (no images). OBJTEST.TAP 11454 bytes,
OBJCTL.TAP 11893.

CPC (CPC.BAT:44, 61, 67-69, 85):

    copy ASSETS\CPC\BLANK.DSK %GAME%.DSK
    copy <ddb> DAAD.DDB
    TOOLS\DRC\MCRF.EXE DAAD.BIN ASSETS\CPC\DCPCIEF3.BIN DAAD.DDB ASSETS\CPC\BLANK.GRA ASSETS\CHARSET\AD8x8.CHR
    TOOLS\CPCDiskXP\CPCDiskXP -File DAAD.BIN -AddToExistingDsk %GAME%.DSK

Bare names, cwd beside the files. MCRF: interpreter 7344 bytes, 912 pad,
DDB at 0x2880, load/run 2112. Disc directory: DAAD.BIN only (system
format).

MSX1 (MSX1.BAT:47-48, 66, 88-96, 100-115):

    copy ASSETS\MSX\MSX1\MSX1.DSK %GAME%.DSK
    copy <ddb> DAAD.DDB
    copy ASSETS\MSX\MSX1\DAAD.MDG
    TOOLS\DD\DD count=218 bs=1 if=DAAD.MDG of=MDG.HEAD
    TOOLS\DD\DD skip=2266 count=34 bs=1 if=DAAD.MDG of=MDG.TAIL
    copy /B MDG.HEAD + ASSETS\CHARSET\AD8x6.CHR + MDG.TAIL DAAD.MDG
    TOOLS\dsktool\dsktool a %GAME%.DSK DAAD.DDB
    TOOLS\dsktool\dsktool a %GAME%.DSK DAAD.MDG
    copy ASSETS\MSX\MSX1\DMSXIEF3.BIN DAAD.Z80
    TOOLS\dsktool\dsktool a %GAME%.DSK DAAD.Z80
    cd ASSETS\MSX\MSX1 & ..\..\..\TOOLS\dsktool\dsktool a ..\..\..\%GAME%.DSK MSXDAAD.COM

MSX1.BAT:104 tests the literal `LANG == "EN"` (not `%LANG%`), so the BAT
always copies the Spanish DMSXISF3.BIN; the English DMSXIEF3.BIN is used
here because the game is English.

PC (PC.BAT:63-64, 113-118, HIRES=0):

    xcopy ASSETS\PC\*.* <tree> /s /y
    copy /Y ASSETS\CHARSET\PC.FNT <tree>\GAME\DAAD.FNT
    copy %GAME%.DDB <tree>\GAME\DAAD.DDB
    echo @dosbox.exe -noconsole > <tree>\%GAME%.BAT
    echo  PCDAAD  >> <tree>\dosbox.conf
    echo exit >> <tree>\dosbox.conf
    echo @PCDAAD   > <tree>\GAME\%GAME%.BAT

PC.BAT:110-111 call `DELETE`, which is not a cmd command (no effect);
skipped.

## Staged legs (owner-run)

sd\LEGCCPC, sd\LEGCMSX and sd\LEGCPC are discharged by the scripted runs
above. As staged:
sd\LEGCCPC (OBJCTL.DSK, OBJTEST.DSK), sd\LEGCMSX (OBJCTL.DSK,
OBJTEST.DSK, init.cfg), sd\LEGCPC (CTL\ and TEST\ DOSBox trees), each
with a STEPS.TXT: launch line, the 37 walk.txt commands with the ZX 48K
control text per step (matches jDAAD's control transcript), control
first, then test, and the pass criterion. Re-staged 2026-10-27 from
4b2f776; the control images hold the same DDB as before. Launch lines:

    cd /d tools\DAAD-READY\TOOLS\CPCE
    CPCE95 -v+ ..\..\..\..\sd\LEGCCPC\OBJCTL.DSK

    cd /d tools\DAAD-READY\TOOLS\openmsx
    openmsx -machine Philips_NMS_8250 -script init.cfg -diska ../../../../sd/LEGCMSX/OBJCTL.DSK

    cd /d sd\LEGCPC\CTL
    OBJCTL.BAT
