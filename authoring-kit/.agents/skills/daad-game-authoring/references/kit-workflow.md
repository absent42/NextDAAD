# Kit workflow

How a DSF and its assets become a folder that boots on a ZX Spectrum Next.
The manual page is [getting started](../../../../docs/getting-started.html).

## Where things go

| What | Where | Notes |
|---|---|---|
| The game source | `<GAME>\<GAME>.DSF`, in a game folder of its own | Select it with `SET GAME=<GAME>` in `CONFIG.local.BAT`; blank works only while exactly one game folder exists |
| The game's settings | `<GAME>\<GAME>.CFG` | Same `SET` lines as `CONFIG.BAT`; copy only the lines you change |
| Location pictures, title | `<GAME>\IMAGES\NNN.png`, `<GAME>\IMAGES\DAAD.png` | Indexed PNG, 320 or 256 wide |
| Sprite sheets | `<GAME>\IMAGES\SPRITES\NNN.png` + `NNN.txt` | |
| Music, effects, samples | `<GAME>\AUDIO\` | `.aks` and `.wav`; see nextdaad-features.md for names |
| Cutscenes | `<GAME>\VIDEO\NNN.mp4` | |
| Fonts, pointers, hints, intro, externs | the game folder: `FONT.CHR`, `POINTER.SPR`, `HINTS.TXT`, `INTRO.TXT`, `GAME.XBN` | |
| Extra parts | `<GAME>\PART2\` to `<GAME>\PART9\` | One DSF each |
| Build output | `RELEASE\<GAME>\`: `<GAME>.NEX` and `DATA\` | Copy the contents of `RELEASE\` to the SD card root |

A text-only game needs none of the asset folders. A game folder is
self-contained: nothing is looked up in the kit root or another game folder.

`STARTER\` is the shipped starter game. Every kit update replaces it, so
never write a game in it. To start a new game: copy `STARTER\` to
`MYGAME\`, rename `STARTER.DSF` and `STARTER.CFG` in the copy to
`MYGAME.DSF` and `MYGAME.CFG` and `AUDIO\STARTER.aks` and
`AUDIO\STARTER_FX.aks` to `AUDIO\MYGAME.aks` and `AUDIO\MYGAME_FX.aks`
(music and effects are taken from the `.aks` named after the game), create `CONFIG.local.BAT` from
`CONFIG.local.BAT.sample` with `SET GAME=MYGAME`, and edit
`MYGAME\MYGAME.DSF`. The copied `.CFG` holds `VIDOPTS_001`/`VIDOPTS_002`
lines tuned for the starter's demo clips; delete them when the clips change.

A `.DSF` loose in the kit root is the old (before v0.12.0) single-game
layout. It still builds, picked when `GAME` is blank and it is the only
root `.DSF`, but it has no `.CFG` and its files sit among the kit's own.

## Build, run, clean

Windows: double-click or run `BUILD.BAT`, `RUN.BAT`, `CLEAN.BAT`, `DEBUG.BAT`.
Linux: `./build.sh`, `./run.sh`, `./clean.sh`, `./debug.sh` (needs PowerShell 7 as `pwsh`).

The build compiles the DSF with the bundled compiler, converts every
asset that changed, copies the interpreter, and ends with
`BUILD OK: RELEASE\<GAME>\ is ready - copy the contents of RELEASE\ to the root of an SD card`.
It is incremental: only changed sources are reconverted. `RUN.BAT`
launches the emulator `EMULATOR` names (CSpect by default, or jNext) on the
selected game, if it is installed under `tools\`; CSpect uses
`RELEASE\<GAME>\` as the emulated card. `CLEAN.BAT` empties
`RELEASE\<GAME>\` (that game only) and `CACHE\jnext\` for a full rebuild. While `STARTER\`
is the game, every build prints a warning that kit updates replace it.

`DEBUG.BAT` builds the same way, also writes source maps (`GAME.DSM`,
`GAME<n>.DSM`) and copies `NEXTDAAD.SYM` into the game folder, installs
the debugger plugin into CSpect's folder, and starts CSpect with the
debugger window. It needs CSpect 4.0 or later and `EMULATOR=cspect` (it
refuses jNext), and ignores `RUN`. Breakpoints and watches persist in
`<GAME>\DEBUGGER.local.TXT`. `RELEASE\<GAME>\` is unchanged. It is an
interactive window: leave running it to the author. While the DSF has
`#debug` (lower case only) every build warns, because the `DEBUG` markers
ship in the release and other DAAD interpreters read them as `NEWTEXT`.
Full behaviour: `docs/debugger.html`.

Helping the author with a bug you cannot see yourself:
- Suggest where to stop: a source line (click its left margin in the
  `Source` tab), a flag that changes or reaches a value, an object that
  moves, a condact, or a process entry. Name the exact line or flag
  number from the DSF.
- `source map is out of date - rebuild` means the source changed since the
  last `DEBUG.BAT`: run `DEBUG.BAT` again, not `BUILD.BAT`.
- If the debugger window misbehaves, read `<GAME>\debugger.log`; it names
  the build, the maps loaded and any fault.

The compile line the build runs, for when you want to check a DSF without
converting assets. Run it from inside the game folder, as the build does,
so `#include` lines resolve there:

    ..\lib\ndrc.exe nextdaad EN MYGAME.DSF ..\RELEASE\MYGAME\DATA\GAME.DDB -v3 -auto-tokens -nxtext
    ../lib/ndrc nextdaad EN MYGAME.DSF ../RELEASE/MYGAME/DATA/GAME.DDB -v3 -auto-tokens -nxtext

Add `-cols=40` for a 40-column game. Compiler errors name the DSF line.
The build refuses `#classic`.

## CONFIG.BAT, the game's .CFG, CONFIG.local.BAT

All three are read as `SET KEY=value` lines, never executed; `REM` lines
are ignored. Order, last wins: `CONFIG.BAT` (kit defaults - do not edit,
an update replaces it), then `<GAME>\<GAME>.CFG` (the game's settings),
then `CONFIG.local.BAT` (machine settings and the game selector). A `GAME`
line in a `.CFG` is ignored with a warning. Copy only changed lines, never
a whole `CONFIG.BAT`.

| Key | Meaning |
|---|---|
| `GAME` | The game folder to build; set in `CONFIG.local.BAT` |
| `RUN` | `1` launches the `EMULATOR` after a successful build |
| `EMULATOR` | blank or `cspect` = CSpect; `jnext` = jNext, which also plays video and streamed sound. `DEBUG.BAT` needs CSpect |
| `COLS` | blank = 80 columns, `40` = 40 (the DSF must also issue `GFX 1 18`) |
| `COMPRESS` | `1` ZX0-compresses pictures |
| `JNEXTDIR`, `JNEXT` | jNext folder (blank = `tools\jnext\`, or `jnext` on PATH on Linux) and full path to the program, for `EMULATOR=jnext` |
| `JNEXTIMG` | jNext's SD-card image; blank = `.jnext/sdcard/` in the home folder. The kit copies it to `CACHE\jnext\card.img` and never changes it |
| `TOOLSDIR`, `CSPECTDIR`, `ARKOSDIR`, `FFMPEGDIR`, `SJASMPLUSDIR` | Tool locations; blank = under `tools\` |
| `VIDOPTS`, `VIDOPTS_NNN`, `VIDFPS`, `VIDASPECT` | Video encoding; per game, in the `.CFG`. vidtune saves `VIDOPTS_NNN` there and refuses `STARTER\` |

## Third-party tools

Only needed for the features that use them. Each goes under `tools\` at
the path in `tools\README.txt`.

| Tool | Needed for |
|---|---|
| CSpect | running the build in an emulator |
| jNext | optional; running with `EMULATOR=jnext`, which plays video |
| Arkos Tracker 3 | any `.aks` music or effects |
| ffmpeg | `.mp4` cutscenes |
| sjasmplus | rebuilding externs with `EXTERNS.BAT` |

## Build errors worth recognising

| Message | Cause |
|---|---|
| `set GAME in CONFIG.local.BAT (found ...)` | `GAME` blank and no single game to pick: several game folders, none, or several root DSFs |
| `<GAME>\ has no <GAME>.DSF` / `<GAME>.DSF not found` | `GAME` names a folder or DSF that is not there |
| `WARNING: RELEASE\ holds ... from an older kit build` | loose pre-v0.12.0 output in `RELEASE\`; delete it by hand |
| `ndrc failed compiling` | the compiler output above it names the line |
| `GAME.DDB is N bytes, over the 65535 limit` / `over the 131070 limit` | the compiler line above names the budget: `Text region goes N bytes over` = text (move to `XMESSAGE`, cut messages), `DDB file goes N bytes over the 65535 memory address boundary` = game logic (cut vocabulary, objects, entries) |
| `uses #classic, which NextDAAD does not support` | delete the `#classic` line |
| `expected a 320 or 256 wide PNG` | resize the picture |
| `must be a paletted 8-bit PNG` | re-export as indexed colour |
| `GAME.AKY is N bytes, over the 10208 song limit` | shorten or rename to `STREAM_NNN.aks` |
| `required tool missing` / `... not found` | install under `tools\` or set the `*DIR` key |
| `CSpect is running - close it before building` | close the emulator |
| `ERROR: EMULATOR=... - use cspect or jnext` | set `EMULATOR` to `cspect` or `jnext`, or blank |
| `ERROR: jNext not found at ...` | install jNext 1.1.87 or later there, or set `JNEXTDIR` in `CONFIG.local.BAT` |
| `ERROR: no jNext SD-card image at ...` | start jNext once to download its image, or set `JNEXTIMG` in `CONFIG.local.BAT` |
| `ERROR: jNext is running - close it before running the game` | close jNext |
| `ERROR: jNext could not write the SD-card image (step N, exit CODE)` | step 1 adds AUTOEXEC.BAS, steps 2-3 the game; exit 1 old jNext, 2 unreadable file, 3 unusable name (rename), 4 exists, 5 bad image (CLEAN.BAT), 6 card full |
| `does not keep sub-microsecond file times` | move the kit to a local NTFS or ext4 drive |

Warnings are advisory; the build continues.

## Runtime errors

Boot failures show a magenta bar on the top row. `E1` means `GAME.DDB` is
missing (the game's `DATA\` folder is not beside `<GAME>.NEX`, or the
`RELEASE\` folder itself was copied instead of its contents);
`E2` a format 1 DDB is over 64K; `E4` it was compiled for another machine;
`E5` a format 2 DDB's text region is damaged (a truncated copy).
`RUNTIME ERROR - E<n>`: 1 invalid location (often `DESC 255`), 4 nested
`DOALL`, 5 a V3 opcode in a V2 database.

Missing assets at runtime (picture, sprite set, font, pointer, part DDB,
`0.XMB`) are silent: the game carries on without them. If something does
not appear, check the file name and number in `RELEASE\<GAME>\DATA\` first.

Save games and extern files (`GAME.HPR`, `GAME.HST`, `TRANS.TXT`) are
written into `DATA\` at runtime.

## Testing on real hardware

Copy the contents of `RELEASE\` to the SD card root and run
`<GAME>\<GAME>.NEX` (with or without a loader intro). Video, streamed
samples and exact timing only behave on real hardware.
