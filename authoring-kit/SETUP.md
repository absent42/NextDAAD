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
- Optional title screen: `IMAGES\DAAD.png`, same art rules as location
  graphics above (converts to `DAAD.NX2` or `DAAD.NXI`) - or, if you already
  have converted art, a ready-made `DAAD.NX2`/`DAAD.NXI` (or its ZX0-compressed
  variant) placed directly in this kit folder, staged to `RELEASE\` as-is. If
  both are present, the `IMAGES\DAAD.png` conversion wins. See "Title screens"
  below.
- Optional custom font: a ready-made `FONT.CHR` (a full 2048-byte glyph
  table) placed directly in this kit folder, staged to `RELEASE\` as-is. If
  your font is a classic 768-byte ZX charset (chars 32-127 only), run
  `lib\fontconv.ps1` first to pad it into a `FONT.CHR`. With no `FONT.CHR`,
  the interpreter's own embedded font plays. See "Custom fonts" below.
- Optional custom mouse pointer: a ready-made `POINTER.SPR` (a raw
  256-byte 16x16 8-bit sprite pattern) placed directly in this kit folder,
  staged to `RELEASE\` as-is. With no `POINTER.SPR`, the interpreter's own
  default arrow plays. See "Custom mouse pointer" below.
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
- Optional video cutscenes in `VIDEO\` (pre-encoded `.vid` files, copied
  as-is - no conversion): `NNN.vid` -> `RELEASE\NNN.VID`, played by
  `GFX n 13`/`GFX n 14`. See "Video cutscenes" below for the formats,
  encoding tools, and playback caveats.

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
`DAAD.NX2`/`DAAD.NXI` title screen (optionally `.zx0`, see "Title screens"
below), any `FONT.CHR` custom font (see "Custom fonts" below), any
`POINTER.SPR` custom mouse pointer (see "Custom mouse pointer" below), any
`GAME.AKY`/`NNN.AKY`/`GAME.SFB`/`NNN.AYS`, any `NNN.WAV`, any `NNN.VID`
(see "Video cutscenes" below), and
`0.XMB` if your DSF uses XMESSAGE/XMES (see section 8). Copy its contents to
the root of an SD card to play on real hardware.

## 6. The starter game

`STARTER.DSF` with example graphics, audio and video ships with the kit, so
a first build works out of the box and shows the NextDAAD-specific condacts
in use: `PICTURE`/`DISPLAY` for location art, `SFX` for music and effects,
`BEEP` for tones, and `GFX` for video cutscenes. In the starter, try the
verbs MUSIC, MUTE, TUNE, BLEEP, ZAP, SAMPLE, MOVIE, and REEL.

## Title screens

Optional: ship `IMAGES\DAAD.png` (or a ready-made `DAAD.NX2`/`DAAD.NXI`, see
section 2) and the game shows it at cold boot - over the boot-autoplay music
(`GAME.AYS`/`GAME.AKY`, if present) - until any key is pressed, then play
begins as normal. No source changes are needed. With no `DAAD.*` file, boot
is unchanged.

Art rules are identical to location graphics (section 2): 8-bit paletted
PNG, 320 wide for full-screen (`DAAD.NX2`) or 256 wide for classic bordered
(`DAAD.NXI`), same `COMPRESS` handling and `.zx0` naming.

A release build that ships a title suppresses its version banner, so the
title is the first thing seen.

The title is root-only - it is never shadowed per-part (see section 9,
"Root-only, never shadowed"): a multi-part game shows the same title at
cold boot regardless of which part is running.

## Custom fonts

Optional: ship a `FONT.CHR` (see section 2) and the interpreter installs it
in place of its own embedded font - a plain byte-for-byte copy into the
tilemap driver's glyph table, no source changes needed. With no `FONT.CHR`,
the embedded font plays, exactly as before this feature existed.

**Format.** `FONT.CHR` is 256 glyphs x 8 rows, 1bpp, exactly 2048 bytes -
the standard raw charset format the whole DAAD/ZX tool ecosystem emits, so
output from CH82CHR, jDAADFontMaker, GCS, and similar font editors works
directly, unmodified, as `FONT.CHR`. Any other size is rejected at boot (a
DEBUG build shows a marker) and the embedded font plays instead.

**Classic 768-byte charsets.** Many ZX font packs and editors instead export
a classic ZX Spectrum charset: characters 32-127 only (96 glyphs x 8 rows,
768 bytes) - for example the `.ch8` files under `tools\demo-files\fonts`.
`lib\fontconv.ps1` accepts either shape:

```
powershell -ExecutionPolicy Bypass -File lib\fontconv.ps1 -In MyFont.ch8 -Out FONT.CHR
```

(PowerShell's default execution policy blocks running a bare `.ps1` script;
`-ExecutionPolicy Bypass -File` is the same shape `audio.bat` already uses
internally for `aysconv.ps1`.)

A 2048-byte input is copied straight through. A 768-byte input is padded
into a full 2048-byte table: it fills glyphs 32-127 (bytes 256-1023) from
your file, keeping `lib\default.chr` (a copy of the interpreter's own
embedded font) for every other glyph (0-31, 128-255). Any other input size
is an error naming both accepted shapes. Place the script's `FONT.CHR`
output directly in this kit folder (section 2) to ship it.

**Which glyphs the engine actually renders.** The full 256-glyph table
(indices 0-255) is addressable, but ordinary game text only ever draws on
part of it: printed bytes 32-127 (the ordinary printable ASCII range) select
glyphs 32-127 - or, when a window forces the "upper charset" (`WIN_FLAGS`
bit 0) or the `GFX ON`/`GFX OFF` print escape is active, the SAME bytes
select glyphs 160-255 instead (glyph = char + 128), a mirrored bold/alternate
variant reachable without doubling vocabulary. Bytes 16-31 and 128-255
select their matching glyph directly (extended/graphics glyphs, no
mirroring). In practice this means a 768-byte classic charset (glyphs
32-127) covers everything a typical DAAD game prints; glyphs 0-31, 128-159
and 160-255 are reachable only through the extended/upper-charset routes
above and keep `default.chr`'s originals unless your `FONT.CHR` supplies the
full 2048 bytes.

**Glyph 32 (space) must stay blank.** The tilemap driver relies on glyph 32
having an all-zero bitmap - it is what gets painted, at the reserved
transparent attribute, into any cell that should show Layer 2 (or whatever
sits beneath the tilemap) through untouched. A `FONT.CHR` that redefines
glyph 32 with non-zero pixels will show ink-coloured specks in those
"transparent" cells instead. `fontconv.ps1` warns (does not fail) if the
input's glyph 32 is non-zero; a hand-built or straight-passthrough
`FONT.CHR` is not checked at boot, so verify this yourself if you edit
glyph 32.

**Per-part fonts.** For a part >= 2, `FONT.CHR` is one of the shadowed
asset kinds - see section 9, "Shadowed assets": a `PART<n>\FONT.CHR`
overrides the root font for that part only, staged automatically by the
existing multi-part asset copy (nothing extra to configure), and falls
back to the root `FONT.CHR` (or the embedded font, if none) if that part
ships no font of its own.

**Reserved for later.** `FONT2.CHR`, `FONT3.CHR`, and so on are reserved
names for a future multi-font-per-game feature; this version only ever
reads `FONT.CHR`, so a stray `FONT2.CHR` in the kit folder or on the SD
card is currently inert.

## Custom mouse pointer

Optional: ship a `POINTER.SPR` (see section 2) and the interpreter installs
it into hardware sprite pattern slot 0 in place of the default arrow - the
existing `MOUSE 1` (`SHOWMS`) upload picks it up automatically the next
time it runs, no source changes needed. With no `POINTER.SPR`, the default
arrow plays, exactly as before this feature existed.

**Format.** `POINTER.SPR` is a raw 16x16, 8-bit-per-pixel hardware sprite
pattern - exactly 256 bytes, one byte per pixel, row-major (row 0 first,
16 bytes per row), no header. Any other size is rejected at boot (a DEBUG
build shows a marker) and the default arrow plays instead.

**Colour values.** Each byte is read by the sprite hardware as an RGB332
colour directly (index N = colour N, the Next's default identity sprite
palette - nothing in this interpreter loads a custom sprite palette, so
this holds for every pointer). $E3 is the hardware's own soft-reset
transparent value - use it for any pixel that should show the background
through. The default pointer uses $00 (black, RGB332) for its outline and
$FF (white) for its fill; any other RGB332 byte value is a valid opaque
colour. The hotspot (registration point) is pixel (0,0), the pattern's
top-left corner - design your artwork with the "business end" of the
pointer there.

**Making one.** Any sprite/tile editor or hex editor that can export a
flat, unheadered 16x16 8-bit-indexed byte dump works - draw against the
Next's standard RGB332-identity palette (palette slot N previewed as
colour N) so the exported index values are already the correct output
bytes, then save/export exactly 256 bytes as `POINTER.SPR`. `gfx2next`'s
`-sprites` mode (`tools\gfx2next`, section 1) does emit a raw, unheadered,
8-bit 256-byte pattern for a 16x16 indexed PNG (verified directly: a
16x16 indexed test image round-tripped through `gfx2next -sprites`
byte-for-byte matches its own source palette indices, no extra header or
padding) - but it is not wired into this kit's build, because it only
comes out correct if the source PNG's palette was authored with index N
already equal to RGB332 colour N; a normal "quantize to a nice-looking
palette" export (the workflow location art and title screens use) would
silently produce the wrong pointer colours. Build your `POINTER.SPR`
directly in a sprite/hex editor, or through `gfx2next -sprites` ONLY if
you have deliberately set up a standard RGB332-identity palette first.

**Per-part pointers.** For a part >= 2, `POINTER.SPR` is one of the
shadowed asset kinds - see section 9, "Shadowed assets": a
`PART<n>\POINTER.SPR` overrides the root pointer for that part only,
staged automatically by the existing multi-part asset copy (nothing extra
to configure), and falls back to the root `POINTER.SPR` (or the default
arrow, if none) if that part ships no pointer of its own.

**Reserved for later.** `MOUSE` sub-command 5 (`POINTERMS`) is accepted
and ignored on this target (see "MOUSE sub-commands" below) - reserved for
a future feature that switches between several loaded pointer shapes at
runtime. This version only ever shows the one pointer installed at boot
or part-switch time.

## Video cutscenes

Optional: drop pre-encoded `.vid` cutscene files in `VIDEO\` (section 2),
numbered by video number, e.g. `VIDEO\001.vid` stages as-is (no
conversion) to `RELEASE\001.VID`. A DSF plays one with `GFX n 13` (play
once) or `GFX n 14` (loop until any key), where `n` is the video number -
`GFX 3 13` plays `003.VID`. These are also reachable through the classic
DOS DAAD symbols `SFX n 9` (`PLAYFLI`) and `SFX n 10` (`PLAYFLIL`) - see
the SFX sub-command table below, rows 9/10, now a real feature on this
target rather than a no-op. Like location art, `PART<n>\NNN.VID` shadows
the root copy for that part only (section 9, "Shadowed assets").

### The six formats

The player identifies which of six formats a `.VID` file is purely from
its file size - nothing to select at the DSF level, any correctly-sized
`.VID` just plays:

| fmt | resolution | palette | fps | audio (encoded rate) |
|---|---|---|---|---|
| 0 | 320x240 | yes | 50/3 | stereo, 15550 Hz |
| 1 | 320x240 | no | 50/3 | stereo, 15550 Hz |
| 2 | 256x240 | yes | 50/3 | stereo, 31100 Hz |
| 3 | 256x240 | no | 50/3 | stereo, 31100 Hz |
| 4 | 256x192 | yes | 25 | mono, 23325 Hz |
| 5 | 256x192 | no | 25 | mono, 23325 Hz |

These rates are exact (re-derived from samples/frame x fps), not the
"~15.6k/31.1k/23.3k" roundings some tool documentation uses.

**Playback audio caveat.** On the current build, the stereo formats play
downsampled from their encoded rate - a memory-constraint tradeoff,
slated for revisiting in a future optimisation pass: formats 2/3 play at
~10.4 kHz (3:1 downsample), formats 0/1 at ~7.78 kHz (2:1 downsample).
The mono formats (4/5) always play at their full encoded rate.

**Performance caveat.** Format 0 (320x240 palette, the highest data-rate
format) may show slight stutter on the current Next core; an upcoming
core release with faster SD reads is expected to improve this. Loop mode
(`GFX n 14`) has a brief audio gap at each restart, by design.

**Redraw after a cutscene.** Video playback is a full-screen takeover,
like `DISPLAY`: register state is restored when it ends, but pixel
content is not. A game must redraw its own picture afterwards - the
starter game's own `MOVIE`/`REEL` verbs do this the same way its `R`
(redraw) verb already does, `CLS` then `RESTART`.

**60Hz displays.** These formats are 50Hz-designed; on a 60Hz display,
expect slower playback and audio popping - an accepted limitation, not a
bug to report.

### Encoding a `.VID`

Two ways to make one - neither is wired into `BUILD.BAT`, both write a
finished `.vid` you drop into `VIDEO\` yourself:

- **MakeVid** (`tools\README.txt`), a GUI tool, for the non-palette
  formats (1/3/5). Its "with palette" formats (0/2/4) are currently
  broken in MakeVid 1.77 - malformed output, raw RGB24 pixel data never
  converted to palette indices (only the top third of each frame
  decodes). Non-palette output is correct; the defect is upstream and a
  report on it is on hold pending this kit's own proven alternative.
- **`lib\videnc.py`** (shipped with this kit), a command-line tool that
  encodes all six formats correctly, including real per-frame adaptive
  palettes - proven on hardware, and the only way to get a working
  palette format (0/2/4) until MakeVid's defect is fixed upstream. Needs
  Python 3, Pillow (`pip install Pillow`), and ffmpeg (default path
  `tools\ffmpeg\bin\ffmpeg.exe`, override with `--ffmpeg PATH`) - the
  only place in this kit's workflow with a dependency beyond the batch
  files and the tools in section 1.

```
python lib\videnc.py INPUT.mp4 VIDEO\001.vid --format 1 --start 00:00:03 --duration 4
```

`--format` is 0-5 (the table above); `--start`/`--duration` cut a clip
from a longer source; `--dither` Floyd-Steinberg dithers the palette
formats (default: no dither). Run `python lib\videnc.py --help` for the
full option list.

**Contiguity.** Files play best contiguous on the SD card - defragment
the card if a video stutters that a straight sector-throughput
calculation says should not. **Classification collision.** A `.VID`
whose size happens to be an exact multiple of an earlier-priority
format's frame size classifies as that earlier format instead, by
design (see the format table's priority order 0-5) - `lib\videnc.py`
detects and fixes this automatically by appending one blank frame at
encode time; a MakeVid-produced file hitting this is rare but possible,
and the fix is the same (append one blank frame).

### The starter game's demo clips

`VIDEO\001.vid` (format 1, 320x240 no-palette - the safe default) and
`VIDEO\002.vid` (format 0, 320x240 palette - the showcase) ship with the
kit so `GFX 13`/`GFX 14` work out of the box. Try the verbs MOVIE (plays
001.VID once) and REEL (loops 002.VID until a key is pressed).

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
whenever your DSF uses either condact (staged into `RELEASE\`
automatically - see below). Two limits to know:

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

`0.XMB` is staged into `RELEASE\` automatically, right after `GAME.DDB`,
whenever your DSF uses XMESSAGE or XMES. DRC writes the file during the
DDB compile step into the DAAD-READY tool folder
(`%TOOLSDIR%\DAAD-READY\0.XMB`); the kit copies it from there to
`RELEASE\0.XMB`, where it must sit alongside `GAME.DDB` on the SD card -
without it, XMESSAGE/XMES would silently no-op at runtime rather than
failing loudly. A DSF with no XMESSAGE/XMES calls produces no `0.XMB`,
and the build stages none.

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

### Appendix D symbol names (SFX and MOUSE)

DAAD Ready's Appendix D lists symbolic names for the sub-command
argument of `SFX` and `MOUSE` (`PLAYSFX`, `SHOWMS`, and so on). The
bundled DRF compiler predefines every one of them, and a DSF written
with the symbolic form compiles byte-identical to the same DSF written
with the raw number - use whichever reads better. Confirmed by
compiling a test suite both ways and comparing the resulting DDBs
byte-for-byte.

**Typo warning:** the DAAD Ready manual's own Appendix D table names
value 10 `FPLAYFLIL`. That is a documentation typo - `FPLAYFLIL` does
not compile. The compiler defines `PLAYFLI` (9) and `PLAYFLIL` (10).

### SFX sub-commands

| n | Symbol | Behaviour on this target |
|---|--------|---------------------------|
| 1 | `PLAYSFX` | Play `NNN.WAV` once. If no matching WAV exists, the same number plays as an AY sound effect from the effects bank instead. |
| 2 | `PLAYSFXL` | As 1, looped. |
| 3 | `PLAYSFXF` | Same as `PLAYSFX` (1) - the DOS-specific file-rate byte does not exist in this toolchain's DDB output, so the WAV's own header rate plays. |
| 4 | `PLAYSFXFL` | Same as `PLAYSFXL` (2), for the same reason. |
| 5 | `STOPSFX` | Stop whichever effect kind is currently active (sample and AY). |
| 6 | `PLAYDRO` | Play music once - a GAME-numbered AYS stream is tried first, an AKY song plays if none exists. On DOS these condacts played OPL music; on this target they are the music surface. |
| 7 | `PLAYDROL` | As 6, looped. |
| 8 | `STOPDRO` | Stop music of both kinds (AYS stream and AKY song). |
| 9 | `PLAYFLI` | Play video `NNN.VID` once - the classic DOS video symbol, now real: identical to `GFX n 13`. See "Video cutscenes" above. |
| 10 | `PLAYFLIL` | As 9, looped until a key is pressed - identical to `GFX n 14`. |

Sample numbers 1-254 may resolve to a WAV or fall back to an AY
effect; 255 is reserved and always plays from the AY effects bank.

### MOUSE sub-commands (partial support)

`MOUSE` support on this target is **partial**: sub-commands 0-3 are
implemented, 4-7 are accepted but not supported. An unsupported
sub-command no-ops silently (a DEBUG build shows a marker), the same
idiom `SFX` uses above for a sub-command it does not recognise.

| n | Symbol | Behaviour on this target |
|---|--------|---------------------------|
| 0 | `RESETMS` | Re-centre the pointer at (160,128), zero the buttons, and re-latch the movement baseline. |
| 1 | `SHOWMS` | Show the hardware sprite pointer. |
| 2 | `HIDEMS` | Hide the hardware sprite pointer. |
| 3 | `GETMS` | Read mouse state into four flags starting at the first argument: `flags[n]` = buttons (idle 0, left 1, right 2, middle 4, chords additive - jdaad parity, not the raw Kempston byte), `flags[n+1]` = column 0-79 (X/8), `flags[n+2]` = row 0-31 (Y/8), `flags[n+3]` = column 0-53 (X/6). |
| 4 | `GETFINEMS` | Not supported - accepted and ignored. |
| 5 | `POINTERMS` | Not supported - accepted and ignored. Reserved for a future feature that switches between several loaded pointer shapes at runtime (see "Custom mouse pointer" above). |
| 6 | `DELTAXMS` | Not supported - accepted and ignored. |
| 7 | `DELTAYMS` | Not supported - accepted and ignored. |

## 9. Multi-part games

A game can ship as several separate DDBs ("parts") that switch between
each other at runtime with `EXTERN n 4` (MALUVA's `XPART n`). Typical
uses: a game too large for one DDB's practical 31744-byte ceiling
(section 8), or a natural chapter/episode structure. This is entirely
optional - a single-part game (this kit's default) never touches any
of the machinery below.

### Layout

- Part 1 is your main `.DSF` (section 2) - built exactly as before,
  staged as `GAME.DDB` at the SD root. Nothing about a single-part
  build changes.
- Parts 2-9 (the interpreter's own supported range) each get a
  `PART<n>\` folder in the kit directory, holding exactly one `.DSF`
  (auto-detected the same way as the main `GAME`) plus that part's own
  already-converted art/audio, if any.
- `BUILD.BAT` compiles each `PART<n>\` DSF the same way as the main
  game and stages the result as `RELEASE\GAME<n>.DDB` +
  `RELEASE\PART<n>\0.XMB` (if that part uses XMESSAGE/XMES), then
  copies every other file from `PART<n>\` into `RELEASE\PART<n>\`
  as-is (no conversion - put ready-to-use `.NX2`/`.NXI`/`.AKY`/`.AYS`/
  `.WAV`/`.VID`/`GAME.SFB`/`FONT.CHR`/`POINTER.SPR` files there, not
  `.png`/`.aks` sources).
- On the SD card this becomes `GAME.DDB`, `GAME2.DDB`, `GAME3.DDB`, ...
  at the root, alongside `PART2\`, `PART3\`, ... folders holding each
  part's own shadowed assets (see "Shadowed assets" below).

The part switch opens its target by the exact name `GAMEn.DDB` - a
stray file beside it (a `GAMEn.DSF` source left next to the compiled
DDB, say) is ignored and harmless.

### Switching parts

- `EXTERN n 4` (`XPART n` under MALUVA) switches the running game to
  part `n` (1-9). It loads `GAMEn.DDB` (`GAME.DDB` for n=1) from the SD
  root.
- If that file is not present, the switch is a silent no-op - the game
  keeps running in the current part, unaffected. A game that ships an
  `EXTERN n 4` trigger must also ship that part's DDB, or the trigger
  quietly does nothing.
- A successful switch is a fresh entry into the new part, not a resume
  - it starts at the new part's own `PRO 0`, never at wherever the
  `EXTERN` was called from.

### Shadowed assets (the PARTn\ probe)

For a part >= 2, these asset kinds probe `PART<n>\<name>` **first**,
then fall back to the game root if not found there: location art (the
whole extension probe chain runs under `PART<n>\`, then again at the
root if that whole pass misses), `NNN.WAV` samples, `NNN.VID` videos
(see "Video cutscenes" above), numbered `NNN.AYS`/`NNN.AKY` songs,
`GAME.SFB`, `0.XMB`, `FONT.CHR` (see "Custom fonts" above), and
`POINTER.SPR` (see "Custom mouse pointer" above).

Root-only, never shadowed: the title screen (`DAAD.*`, shown once at
cold boot only) and the boot-autoplay default song (`GAME.AYS`/
`GAME.AKY`). The `SFX` music sub-commands' own `n=255` sentinel (the
"play `GAME.AYS`/`GAME.AKY`" case, section 8) is **also** always
root-only and reachable identically from every part - `SFX 255 6` or
`SFX 255 7` plays the game's theme from anywhere, "play the game theme
anywhere" by design, not a bug if you expected a per-part override.

Part 1 never probes `PART<n>\` at all - a part-1-only game is
byte-identical to a plain single-part build.

### What carries across a switch, what does not

- **All 256 flags carry verbatim.** Score, turns, and every other
  system or user flag survive a switch unchanged (see caveat 6 below).
- **Object locations carry by index**, for as many objects as both
  parts define in common (caveats 1, 2, 4).
- **Object attributes and descriptions do not carry** - weight,
  container/wearable bits, extended attributes, and text always come
  from the currently active part's own DDB (caveat 3).
- **Vocabulary is per-part and entirely independent.** A word's
  spelling, its ID, and whether it exists at all can differ freely
  between parts - nothing forces part 2's verb/noun IDs to agree with
  part 1's, and nothing carries them if they did. Only OBJECT NUMBERS
  need a shared convention across parts (caveat 1); vocabulary needs
  none.

### Save, load, and RAMSAVE across parts

SAVE always records the current part number in the file (see the
version note below); LOAD reads it back and switches automatically if
it differs from the running part - a cross-part LOAD is a part entry,
exactly like `EXTERN n 4`, not a resume (caveat 7). Save files share
one filename namespace in the game root regardless of part (caveat 9)
- SAVE/LOAD never look inside `PART<n>\`.

**Save-file version note:** save files are length-detected - a
same-part-only save has no trailing part byte (v1), a save written by
this kit's interpreter has one appended (v2). A malformed or hand-edited
v1 file (a stray trailing byte, a corrupted header count) can
misclassify between the two, but the outcome is always bounded to a
wrong-part restore or a clean rejection - never file corruption. Only
distribute save files your own build actually wrote; do not hand-edit
them.

RAMSAVE/RAMLOAD (caveat 8) use one buffer that also survives a switch -
a RAMLOAD taken two parts later still restores to wherever the RAMSAVE
was last taken, the "died, try again" checkpoint feature. A cross-part
RAMLOAD is always a full restore: it ignores RAMLOAD's own "restore up
to flagno" partial-restore argument, which only applies within the
same part. Refresh RAMSAVE in the new part's `PRO 0` after a switch if
you want the checkpoint to track it.

### Author caveats

1. **OBJECT NUMBERING IS THE AUTHOR'S CONTRACT**: the carry copies
   object locations BY INDEX. Object 7 in part 1 must mean the same
   thing as object 7 in part 2, or a carried lamp becomes whatever part
   2 defined at that index. Keep a shared object-numbering map across
   parts; define cross-part objects at the same indexes in every part.
2. **THE WHOLE TABLE CARRIES, NOT JUST THE INVENTORY**: objects left in
   part-1 rooms arrive in part 2 holding part-1 location NUMBERS, which
   now name different rooms (or nothing). If only carried/worn objects
   matter across a boundary, have the new part's PRO 0 re-PLACE or
   ABSENT everything else (classic housekeeping idiom).
3. Attributes are PER-PART: weight, container/wearable bits, and
   descriptions come from the ACTIVE part's DDB - a carried object
   weighs what part 2 says it weighs.
4. Object counts may differ: objects the new part defines beyond the
   old part's count start at the new part's compiled initial locations.
5. Inventory limits are per-part (CTL): arriving with more carried
   objects than the new part's limit is stable until the next GET;
   authors who lower the limit should handle the overflow in PRO 0.
6. ALL 256 FLAGS CARRY - there is no clean slate: a part that assumes
   its scratch flags start at zero must zero them in PRO 0 (or the
   previous part clears them before switching). System flags carry
   too: score/turns carry naturally; the location flag holds a part-1
   room number until PRO 0 places the player - always set the start
   location first.
7. SAVE/LOAD: a v2 save records flags + objects + part; loading it from
   ANY part lands in the SAVED part - all caveats above apply to the
   restored state exactly as to a live switch. Cross-part LOAD enters
   the saved part at PRO 0 (it does not resume mid-turn); same-part
   LOAD behaves as classic DAAD.
8. RAMSAVE is ONE SLOT and survives switches: a RAMLOAD two parts later
   restores to wherever the RAMSAVE was taken. That is the death-retry
   feature - but a stale slot restores a stale part; authors using
   RAMSAVE for checkpoints should refresh it after each switch (RAMSAVE
   in PRO 0).
9. Save files share one namespace in the game root regardless of part;
   identical names overwrite across parts.
