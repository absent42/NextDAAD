# Kit workflow

How a DSF and its assets become a folder that boots on a ZX Spectrum Next.
The manual page is [getting started](../../../../docs/getting-started.html).

## Where things go

| What | Where | Notes |
|---|---|---|
| The game source | one `*.DSF` in the kit root | Auto-detected when it is the only DSF; otherwise set `GAME=` in `CONFIG.BAT` |
| Location pictures, title | `IMAGES\NNN.png`, `IMAGES\DAAD.png` | Indexed PNG, 320 or 256 wide |
| Sprite sheets | `IMAGES\SPRITES\NNN.png` + `NNN.txt` | |
| Music, effects, samples | `AUDIO\` | `.aks` and `.wav`; see nextdaad-features.md for names |
| Cutscenes | `VIDEO\NNN.mp4` | |
| Fonts, pointers, hints, intro | kit root: `FONT.CHR`, `POINTER.SPR`, `HINTS.TXT`, `INTRO.TXT` | |
| Extra parts | `PART2\` to `PART9\` | One DSF each |
| Build output | `RELEASE\` | Copy its contents to the SD card root |

A text-only game needs none of the asset folders.

## Build, run, clean

Windows: double-click or run `BUILD.BAT`, `RUN.BAT`, `CLEAN.BAT`.
Linux: `./build.sh`, `./run.sh`, `./clean.sh` (needs PowerShell 7 as `pwsh`).

The build compiles the DSF with the bundled compiler, converts every
asset that changed, copies the interpreter, and ends with
`BUILD OK: RELEASE\ is ready to copy to an SD card`. It is incremental:
only changed sources are reconverted. `RUN.BAT` launches CSpect on
`RELEASE\` if CSpect is installed under `tools\`. `CLEAN.BAT` empties
`RELEASE\` for a full rebuild.

The compile line the build runs, for when you want to check a DSF without
converting assets (run from the kit root):

    lib\ndrc.exe nextdaad EN GAME.DSF RELEASE\GAME.DDB -v3 -auto-tokens
    lib/ndrc nextdaad EN GAME.DSF RELEASE/GAME.DDB -v3 -auto-tokens

Add `-cols=40` for a 40-column game. Compiler errors name the DSF line.
The build refuses `#classic`.

## CONFIG.BAT

Read as `KEY=value` lines, not executed. `CONFIG.local.BAT` is read after
it and wins, for machine-specific paths.

| Key | Meaning |
|---|---|
| `GAME` | DSF base name when there is more than one |
| `RUN` | `1` launches CSpect after a successful build |
| `COLS` | blank = 80 columns, `40` = 40 (the DSF must also issue `GFX 1 18`) |
| `COMPRESS` | `1` ZX0-compresses pictures |
| `TOOLSDIR`, `CSPECTDIR`, `ARKOSDIR`, `FFMPEGDIR`, `SJASMPLUSDIR` | Tool locations; blank = under `tools\` |
| `VIDOPTS`, `VIDOPTS_NNN`, `VIDFPS`, `VIDASPECT` | Video encoding |

## Third-party tools

Only needed for the features that use them. Each goes under `tools\` at
the path in `tools\README.txt`.

| Tool | Needed for |
|---|---|
| CSpect | running the build in an emulator |
| Arkos Tracker 3 | any `.aks` music or effects |
| ffmpeg | `.mp4` cutscenes |
| sjasmplus | rebuilding externs with `EXTERNS.BAT` |

## Build errors worth recognising

| Message | Cause |
|---|---|
| `set GAME in CONFIG.BAT` | zero or several DSFs in the root |
| `ndrc failed compiling` | the compiler output above it names the line |
| `GAME.DDB is N bytes, over the 65535 limit` | move text to `XMESSAGE`, cut messages |
| `uses #classic, which NextDAAD does not support` | delete the `#classic` line |
| `expected a 320 or 256 wide PNG` | resize the picture |
| `must be a paletted 8-bit PNG` | re-export as indexed colour |
| `GAME.AKY is N bytes, over the 10208 song limit` | shorten or rename to `STREAM_NNN.aks` |
| `required tool missing` / `... not found` | install under `tools\` or set the `*DIR` key |
| `CSpect is running - close it before building` | close the emulator |
| `does not keep sub-microsecond file times` | move the kit to a local NTFS or ext4 drive |

Warnings are advisory; the build continues.

## Runtime errors

Boot failures show a magenta bar on the top row. `E1` means `GAME.DDB` is
missing (the `RELEASE\` folder itself was copied instead of its contents);
`E2` the DDB is over 64K; `E4` it was compiled for another machine.
`RUNTIME ERROR - E<n>`: 1 invalid location (often `DESC 255`), 4 nested
`DOALL`, 5 a V3 opcode in a V2 database.

Missing assets at runtime (picture, sprite set, font, pointer, part DDB,
`0.XMB`) are silent: the game carries on without them. If something does
not appear, check the file name and number in `RELEASE\` first.

## Testing on real hardware

Copy the contents of `RELEASE\` to the SD card root and run
`nextdaad.nex` (or `<GAME>.NEX` when there is a loader intro). Video,
streamed samples and exact timing only behave on real hardware.
