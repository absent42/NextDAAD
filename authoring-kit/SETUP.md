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
| Arkos Tracker 3 | `SongToAky.exe`, `SongToSoundEffects.exe`, `SongToYm.exe` | https://www.julien-nevo.com/arkostracker/index.php/download/ | `..\tools\ArkosTracker3\tools\` |
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
  - `STREAM_NNN.aks` - songs too big for the `NNN.aks` song slot (10208
    bytes), streamed from SD card instead; also selected by `SFX n 6/7`.
    Needs Arkos Tracker 3's `SongToYm.exe` (path via `TOOLSDIR`, see above).
  - `<GAME>_FX.aks` - the sound-effects bank, played by `SFX n 1`.
- Optional sampled sound in `AUDIO\` (WAV files, copied as-is - no conversion):
  - `NNN.wav` - a digital sample played by `SFX n 1` (once) or `SFX n 2` (looped).
    `SFX n 1/2` looks for `NNN.WAV` first and falls back to the AY effect bank
    if the WAV is absent, so a sample and an AY effect cannot share a number.
    WAV must be **PCM, mono, 8-bit unsigned**, sample rate 3500-20000 Hz;
    it plays at the file's own sample rate, no resampling. You supply it
    in that format - the build does not convert it. See section 8 for
    size guidance and how large samples are handled.

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
`nextdaad.nex`, `GAME.DDB`, any `NNN.NX2`/`NNN.NXI` (optionally `.zx0`), any
`GAME.AKY`/`NNN.AKY`/`GAME.SFB`/`NNN.AYS`, and any `NNN.WAV`. Copy its
contents to the root of an SD card to play on real hardware. If your DSF
uses XMESSAGE/XMES, see the note in section 8 - `0.XMB` needs one manual
copy step the kit does not yet automate.

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

## 8. Authoring notes

A few DSF-authoring facts worth knowing once a game grows past the
starter's size - none of this is enforced by the kit build scripts;
DRC (the compiler) or the interpreter enforce it, and these notes
exist so a compile error or a truncated feature makes sense when you
hit it.

### DDB size: the 31744-byte ceiling

The DDB format DRC compiles for this target (the classic ZX addressing
scheme) uses 16-bit pointers based at $8400, the classic ZX DAAD load
address. That caps the whole compiled DDB - vocabulary, messages,
objects, locations, connections, processes, everything DRC writes into
`GAME.DDB` - at 31744 bytes ($8400 to $FFFF). This is a DRC/compiler
format ceiling, not a NextDAAD interpreter limit (the interpreter
itself accepts a DDB up to 128K), but it is the ceiling a growing game
actually reaches first.

The relief valve is XMESSAGE, below: moving text out of the DDB and
into `0.XMB` frees the same bytes inside the 31744-byte budget, at the
cost of the separate external-text budget instead. A game approaching
the ceiling should move its largest or least-frequently-seen text
(long room descriptions, help text, endgame text) to XMESSAGE first.

### XMESSAGE / XMES

XMESSAGE (adds a trailing newline) and XMES (does not) print text
stored externally in `0.XMB`, a file DRC writes during compilation
whenever your DSF uses either condact (see the kit limitation note
below - getting this file into `RELEASE\` currently needs one manual
step). Two limits to know:

- **511 characters per call, practical limit.** A single XMESSAGE/XMES
  call is not meant to hold a full page of text. For longer passages,
  chain several calls back to back - use XMES (no added newline) for
  the earlier calls so the text reads as one continuous block, and
  XMESSAGE (or a trailing newline token) only for the last one.
- **64K total, compiled.** `0.XMB` holds the compiled (token-compressed)
  bytes of every XMESSAGE/XMES call in your whole game, back to back,
  with no gap or padding between entries on this target. That 64K is a
  budget shared across the WHOLE game, not per call - a game that
  leans heavily on XMESSAGE should watch its total external-text
  volume, not just individual message length.

**Kit limitation:** `BUILD.BAT` does not currently copy `0.XMB` into
`RELEASE\`. DRC writes it during the DDB compile step into the
DAAD-READY tool folder (`%TOOLSDIR%\DAAD-READY\0.XMB`) and it stays
there - it is not cleaned up or moved. If your DSF uses XMESSAGE or
XMES, copy that file to `RELEASE\0.XMB` by hand after building
(alongside `GAME.DDB`); without it, XMESSAGE/XMES silently no-op at
runtime rather than failing loudly. This is a gap in the kit scripts,
not the compiler or the interpreter - worth fixing in a future kit
update.

### WAV samples

Sample files (`NNN.wav` in `AUDIO\`, section 2) must be PCM, mono,
8-bit unsigned, sample rate 3500-20000 Hz taken from the file's own
header - the interpreter does not resample, and the kit copies WAV
files as-is (you supply them already in this format).

Size is bounded by the Next's available RAM rather than one fixed
buffer: samples stream into allocated 16K RAM banks at load time (the
same banked-streaming mechanism a big AYS song uses, below), so a
sample is not capped at whatever fits in a single fixed slot. As a
practical guide: **up to 48K always has room**, on any Next, regardless
of what else is loaded (three RAM banks are reserved for audio use
first, ahead of location art or anything else). Bigger samples work
too, up to a generous sanity ceiling, but then compete with Layer 2
picture caching and streamed songs for the remaining RAM - test on the
RAM configuration (1MB/2MB) you expect players to use if you rely on a
large sample.

### AYS streamed songs

The AKY song slot (`<GAME>.aks`/`NNN.aks`, section 2) is fixed-size -
10208 bytes encoded - and most real multi-channel tunes do not fit it.
`STREAM_NNN.aks` sources (section 2) convert instead to `NNN.AYS`, a
per-frame AY-register-delta stream played back from SD rather than
held resident, with no fixed-slot size limit (the same RAM-bounded
model as big WAV samples, above). The kit's own converter,
`lib\aysconv.ps1`, is called automatically by `lib\audio.bat` during a
normal `BUILD.BAT` run - there is nothing to invoke by hand beyond
having Arkos Tracker 3 installed. `SongToYm.exe`'s path comes from
`CONFIG.BAT`'s existing `TOOLSDIR` setting
(`%TOOLSDIR%\ArkosTracker3\tools\SongToYm.exe`), the same as every
other Arkos tool the kit uses.

### DRB 0.36: BEEP/PAUSE timing

The bundled compiler is DRF 0.40 + DRB 0.36. If you are copying BEEP
or XPLAY timings from an older DAAD/MALUVA guide, note that DRB 0.36
retuned XPLAY's generated BEEP/PAUSE durations (base note length, plus
a -24 semitone pitch adjustment for the ZX/Next target) relative to
older DRB versions. Trust what the compiler actually produces - test
the tone/timing in CSpect or on hardware - over duration tables in
older documentation.
