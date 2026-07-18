# NextDAAD Authoring Kit - Setup and Usage

This kit builds a ready-to-run ZX Spectrum Next DAAD adventure from your DSF
source, plus optional location graphics and AY audio. It does not compile the
interpreter - it ships a pre-built `nextdaad.nex` and assembles everything into
a `RELEASE\` folder you copy to an SD card (or run in an emulator).

## 1. Requirements

- Windows (the scripts are Windows batch files).
- The tools below, which are NOT shipped with the kit. Download each and place
  it where the kit expects it (paths are relative to this kit folder; they are
  set in `CONFIG.BAT` via `TOOLSDIR` and `NEXFILE`).

| Tool | Provides | Download | Place at |
|------|----------|----------|----------|
| DAAD Ready | DRC compiler (`DRF.exe`, `DRB.PHP`) and PHP | https://www.ngpaws.com/daadready/ | `..\tools\DAAD-READY\` |
| Gfx2Next | PNG to Layer 2 conversion | https://www.rustypixels.uk/gfx2next/ | `..\tools\gfx2next\gfx2next.exe` |
| Arkos Tracker 3 | `SongToAky.exe`, `SongToSoundEffects.exe` | https://www.julien-nevo.com/arkostracker/index.php/download/ | `..\tools\ArkosTracker3\tools\` |
| CSpect | Emulator for testing | https://mdf200.itch.io/cspect | `..\tools\CSpect\CSpect.exe` |
| nextdaad.nex | The interpreter | NextDAAD project build output | `..\build\nextdaad.nex` |

If you keep your tools elsewhere, edit `TOOLSDIR` and `NEXFILE` in
`CONFIG.BAT` to point at them.

## 2. Your game files

Put these in this kit folder:

- Your adventure source as a single `.DSF` file. If you have exactly one, the
  build finds it automatically; otherwise set `GAME=` (its base name, no
  extension) in `CONFIG.BAT`.
- Optional location graphics in `IMAGES\`, named by picture number, e.g.
  `001.png`. Each must be an 8-bit PALETTED PNG (indexed, max 256 colours) -
  gfx2next rejects truecolour images; export/quantize to an indexed palette in
  your image editor first. A 320-pixel-wide PNG becomes full-screen art; a
  256-pixel-wide PNG becomes classic bordered art. Any other width is rejected
  with an error.
- Optional audio in `AUDIO\` (Arkos `.aks` sources, converted at build time):
  - `<GAME>.aks` - background music, auto-played at boot.
  - `NNN.aks` - songs selected in-game by `SFX n 6` (once) or `SFX n 7` (loop).
  - `<GAME>_FX.aks` - the sound-effects bank, played by `SFX n 1`.
- Optional sampled sound in `AUDIO\` (WAV files, copied as-is - no conversion):
  - `NNN.wav` - a digital sample played by `SFX n 1` (once) or `SFX n 2` (looped).
    `SFX n 1/2` looks for `NNN.WAV` first and falls back to the AY effect bank
    if the WAV is absent, so a sample and an AY effect cannot share a number.
    WAV must be **PCM, mono, 8-bit**; it plays at the file's own sample rate.
    You supply it in that format - the build does not convert it.

## 3. Configuration (CONFIG.BAT)

| Setting | Meaning |
|---------|---------|
| `GAME` | Base name of your `.DSF`. Blank = auto-detect the single `.DSF`. |
| `COMPRESS` | `1` = ZX0-compress graphics (smaller); `0` = raw. |
| `RUN` | `1` = launch CSpect after a successful build; `0` = build only. |
| `TOOLSDIR` | Folder holding the tools above (default `..\tools`). |
| `NEXFILE` | The interpreter to ship (default `..\build\nextdaad.nex`). |

## 4. Build and run

- Double-click `BUILD.BAT`. It compiles the DDB, converts graphics and audio,
  copies the interpreter, and (if `RUN=1`) launches CSpect.
- `RUN.BAT` launches CSpect on the current `RELEASE\` without rebuilding.
- `CLEAN.BAT` empties `RELEASE\` and removes build intermediates.

The build stops at the first error with a message naming the cause (bad source,
missing tool, wrong image width, over-size asset). A pure-text game with no
`IMAGES\` or `AUDIO\` folder builds fine - graphics and audio are optional.

## 5. Output

After a build, `RELEASE\` holds the complete SD-card image:
`nextdaad.nex`, `GAME.DDB`, any `NNN.NX2`/`NNN.NXI` (optionally `.zx0`), and any
`GAME.AKY`, `NNN.AKY`, `GAME.SFB`. Copy its contents to the root of an SD card
to play on real hardware.

## 6. The starter game

`STARTER.DSF` with example graphics and audio ships with the kit, so a first
build works out of the box and shows the NextDAAD-specific condacts in use:
`PICTURE`/`DISPLAY` for location art, `SFX` for music and effects, and `BEEP`
for tones. In the starter, try the verbs MUSIC, MUTE, TUNE, BLEEP, and ZAP.

## 7. Troubleshooting

- "required tool missing" - the named path does not exist; fix `TOOLSDIR`/
  `NEXFILE` or install that tool.
- "CSpect is running - close it before building" - CSpect holds `RELEASE\`
  files open; close it and rebuild.
- "expected a 320 or 256 wide PNG" - resize the named image to exactly 320 or
  256 pixels wide.
- "GAME.AKY is ... over the ... limit" - the tune is too large; shorten it or
  reduce channels in Arkos Tracker.
- Effects bank warnings are non-fatal - the game still builds without
  `GAME.SFB`.
