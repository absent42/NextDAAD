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
- Optional video cutscenes in `VIDEO\`, two source kinds:
  - `NNN.mp4` (or anything ffmpeg reads, renamed to `.mp4`) - encoded to
    native NXV automatically by the build; the resulting `NNN.vid` is
    kept beside the source as an encode cache, so a slow encode runs
    once per source change, not once per build.
  - `NNN.vid` - a pre-encoded NXV file, staged as-is.
  Both end up as `RELEASE\NNN.VID`, played by `GFX n 13`/`GFX n 14`.
  See "Video cutscenes" below for the shapes, encoding tools, and
  playback notes.

## 3. Configuration (CONFIG.BAT)

| Setting | Meaning |
|---------|---------|
| `GAME` | Base name of your `.DSF`. Blank = auto-detect the single `.DSF`. |
| `COMPRESS` | `1` = ZX0-compress graphics (smaller); `0` = raw. |
| `RUN` | `1` = launch CSpect after a successful build; `0` = build only. |
| `TOOLSDIR` | Folder holding the tools above (default `tools`). |
| `NEXFILE` | The interpreter to ship (default `nextdaad.nex`). |
| `VIDASPECT`, `VIDFPS`, `VIDOPTS`, `VIDOPTS_NNN` | Video cutscene encoding - see "Video cutscenes" below. |

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

Full-screen, full-motion video with synchronised audio, in NextDAAD's
own native NXV format. Drop a video source in `VIDEO\` (section 2),
numbered by video number - `VIDEO\001.mp4` is encoded by the build to
`VIDEO\001.vid` (the encode cache, made once per source change) and
staged as `RELEASE\001.VID`; a pre-encoded `VIDEO\001.vid` with no
`.mp4` beside it stages as-is. A DSF plays one with `GFX n 13` (play
once) or `GFX n 14` (loop until any key), where `n` is the video
number - `GFX 3 13` plays `003.VID`. Both are also reachable through
the classic DOS DAAD symbols `SFX n 9` (`PLAYFLI`) and `SFX n 10`
(`PLAYFLIL`) - see the SFX sub-command table below, rows 9/10, now a
real feature on this target rather than a no-op. Like location art,
`PART<n>\NNN.VID` shadows the root copy for that part only (section 9,
"Shadowed assets").

Video is designed for a 2MB Next (the standard fit on issue 2 boards
and later): playback buffers through a large pool of RAM banks, and a
1MB machine has too small a pool to hold or stream clips reliably.

### Shapes and quality

An NXV file is fully self-describing (a real header - nothing to
select at the DSF level). NXV v2 encodes to a *shape* - any Layer 2
width (256 or 320) by any height from 1 line to the mode's full 192 or
256 - rather than a fixed profile. Five preset shapes ship:

| Preset | Shape | Screen mode | Displayed aspect | Character |
|---|---|---|---|---|
| `full` | 320x256 | 320-wide, full height | 4:3, edge to edge | The whole screen. Heaviest data rate, so quality gives way first. |
| `16:9` | 320x192 | 320-wide, letterboxed | 16:9 | The sweet spot for modern widescreen sources. |
| `scope` | 320x144 | 320-wide, letterboxed | ~2.35:1 | Cinematic scope. Small surface, high quality. |
| `classic` | 256x192 | 256-wide, bordered | 4:3 | The classic Spectrum frame. Cheapest 4:3. |
| `classic-wide` | 256x144 | 256-wide, bordered + letterboxed | 16:9 | Cheapest widescreen of all. |

All shapes default to 25 fps and carry 256-colour pictures with
adaptive palettes and full-rate audio - stereo at 15625 Hz by default,
mono at 23325 Hz with `--mono`. No decimation: what the encoder writes
is what plays. Letterbox bars cost zero file bytes (the player renders
them black). Sources are centre-cropped to the shape's exact displayed
aspect, never distorted.

**Smaller shapes come out better.** The player's data budget (SD
streaming rate plus decode time) is fixed, so quality scales inversely
with pixel count: a clip encoded at a smaller height keeps more detail
per pixel at the same data rate - roughly 1.7x the bytes per pixel at
`classic` versus `full`. If a clip looks rough at `full`, re-encode it
letterboxed. Two caveats: hard content (constant whole-frame motion,
noise, fades) eats budget regardless of shape, and the letterboxed
320-wide shapes carry a small decode surcharge for the gapped surface
(~1.15x), which makes `16:9` the usual best trade for widescreen
sources.

**Free heights.** Beyond the presets, any `WIDTHxHEIGHT` is a valid
shape (`320x150`, `256x100`, ...), and `--aspect` derives the height
for a target displayed aspect ratio - `--aspect 2.35` gives true
cinema scope, with the 320-wide mode's non-square pixels corrected
for automatically.

**fps floors.** Frame rate is free (default 25) down to a hard floor
set by audio: the player feeds audio from 1280-byte double-buffer
halves, so one frame may carry at most 1280 audio bytes. Stereo at
15625 Hz needs 24.40 fps or more; mono at 23325 Hz needs 18.22 fps or
more. The encoder refuses an encode below the floor and names the
remedy (raise fps, or switch to `--mono` if mono fits).

**Encode time is quality.** The encoder is deliberately slow - it
spends its time squeezing the best picture into the fixed playback
budget. Expect minutes per clip, once per source change (the build
caches the result).

### Configuring the build's encode pass

The build encodes every `VIDEO\NNN.mp4` with settings from
`CONFIG.BAT`:

| Setting | Meaning |
|---------|---------|
| `VIDASPECT` | Shape for every encode: a preset name, `WIDTHxHEIGHT`, or a bare aspect number (e.g. `2.35` - free height at 320 wide). Blank = `full`. |
| `VIDFPS` | Frames per second. Blank = 25. |
| `VIDOPTS` | Extra encoder options for every encode (e.g. `--mono --dither`). |
| `VIDOPTS_NNN` | Extra options for video `NNN` only (3-digit number), appended after `VIDOPTS`. For most repeated options videnc takes the last occurrence, so `VIDOPTS_NNN` wins over `VIDOPTS` - except `--aspect`, which videnc always takes over `--shape` regardless of order; a `VIDOPTS_NNN` that sets its own `--shape`/`--width`/`--aspect` still wins for shape (the encode pass suppresses `VIDASPECT` for that video rather than relying on order). |
| `VIDPROFILE` | Deprecated v1 name, honored one release: `n0`-`n4` map to the nearest v2 shape (and, when `VIDFPS` is blank, that profile's own baked fps, floored to the audio-legal minimum) when `VIDASPECT` is blank. |

The `.vid` beside the source is an encode cache keyed on both the
`.mp4`'s timestamp and a hash of the effective `VIDASPECT`/`VIDFPS`/
`VIDOPTS`/`VIDOPTS_NNN` settings for that video (stored in a sidecar,
`VIDEO\NNN.vid.args`) - changing any of these settings is detected
automatically and forces a re-encode; there is nothing to delete by
hand. For full per-file control (clipping, shapes per video), use
`VIDOPTS_NNN` or run the encoder by hand (below).

### Encoding tools

The build's encode pass needs an encoder and ffmpeg, both resolved
from `TOOLSDIR` (section 1):

- **`videnc.exe`** (`tools\videnc\videnc.exe`) - the standalone
  encoder, SHIPPED with this kit (the one bundled tool binary; no
  Python needed, no download). Preferred automatically.
- **`lib\videnc.py`** - the same encoder as a script, the fallback if
  videnc.exe is ever missing and the source it is built from. Needs
  Python 3, Pillow and numpy (`pip install Pillow numpy`).
- **ffmpeg** (`tools\ffmpeg\bin\ffmpeg.exe`) - required either way for
  reading the source video; see `tools\README.txt` for the download.

None of this is needed for pre-encoded `.vid` files - a kit with only
`.vid` sources (or no `VIDEO\` at all) builds with no encoder present.

Run the encoder by hand for per-file control or to cut a clip from a
longer source:

```
videnc.exe INPUT.mp4 VIDEO\001.vid --shape classic --start 00:00:03 --duration 4
```

(or `python lib\videnc.py ...`, same options). `--shape` is a preset
or `WIDTHxHEIGHT`; `--aspect` derives a free height instead;
`--fps` sets the frame rate; `--start`/`--duration` cut a clip;
`--mono` halves the audio stream; `--dither` Floyd-Steinberg dithers
(default: no dither). Run with `--help` for the full list, and see
`lib\videnc-README.md` for the options and format details.

### Streaming, resident and direct delivery

Delivery is automatic - nothing to choose at authoring time. A file
that fits the player's RAM bank pool (about 1.2 MB on a fresh boot) is
loaded whole and played from RAM; a bigger file streams from SD
through a prefetch ring of the same banks. Either way playback runs at
true rate.

Because streaming has a fixed supply rate, the encoder checks every
over-pool-size encode against it and *refuses* one that could not
stream ("error: this encode cannot stream - mean supply utilization
N.NN > 1.00 ..."). The message shows where the time goes (decode ms +
SD fetch ms per frame period) and names the remedies: the exact
`--stream-budget` value that fits (it scales the encoder's quality
caps down to streamable), a smaller shape, a lower fps, or a shorter
clip. `--stream-budget` is advisory-precise: after a large change,
re-encode and let the gate re-check. A warning (not a refusal) above
0.90 utilization means an at-capacity encode - fine on a healthy card,
with the ring absorbing bursts.

**Direct-serve (expert).** `--direct` (per-video via `VIDOPTS_NNN`)
writes an uncompressed encode the player serves straight from SD to
the screen - no delta decode, pixel-exact every frame. The catch is a
strict at-rate envelope with no ring to absorb bursts: at 25 fps
stereo it tops out around 256x133, and the gate refuses anything the
SD wire cannot sustain - there is deliberately no slow-playback
opt-out (every shipped mode plays at true rate). The refusal message
prints the live envelope menu for your width: the at-rate stereo and
mono heights, and how far the mono fps floor opens it (256x187-class
at 18.22 fps mono). For almost all content the normal delta encoder
is the better tool; `--direct` exists for encodes that must be
pixel-exact.

### Playback notes

**Game audio during playback.** A cutscene owns the sound hardware
while it plays: a playing sample is stopped, not resumed afterwards; AY
music is frozen in place (paused, not stopped) and resumes
automatically the instant playback ends. No author action needed either
way.

**Automatic picture restore.** When a cutscene ends, the player puts
the screen back by itself: the visible picture surface AND its palette
are snapshotted before the video starts and restored before the screen
is re-shown - no post-video redraw is needed (the starter's MOVIE verb
is just the play). Details worth knowing: the hidden back surface is
NOT preserved (its contents are undefined after a video - only matters
if a game draws there directly), the snapshot reserves a few memory
banks per session (a video refuses with `VID NOBANK2` if the pool
cannot cover it - on the 2MB baseline that takes a heavily-loaded pool
(gfx cache pressure) to bite; unexpanded/1MB machines are outside
video support entirely, since the shared allocator pool there is only
the 14-bank base model with no expansion banks behind it - the same
`VID NOBANK2` path, just triggered far more readily), and a text-only
game with the picture layer hidden pays nothing. A full
redescribe (`CLS` then `RESTART`, the starter's REEL verb) remains a
scene-change choice when the story moves on - a choice, no longer a
necessity.

**Contiguity.** Videos stream from the SD card at a rate that assumes
the file is reasonably contiguous. A heavily fragmented file (more
than 32 fragments) refuses to play; defragment the card (or re-copy
the file to a freshly formatted card) if a video will not start or
stutters.

**60Hz displays.** NXV is 50Hz-designed (frames present on the 50Hz
vblank cadence); on a 60Hz display, expect slower playback and audio
popping - an accepted limitation, not a bug to report.

### The starter game's demo clips

`VIDEO\001.mp4` (encoded at the `full` 320x256 preset, streamed - its
shipped `VIDOPTS_001` carries the `--stream-budget` the supply gate
suggested) and `VIDEO\002.mp4` (encoded at `16:9` 320x192 via the
shipped `VIDOPTS_002`) build with the kit so `GFX 13`/`GFX 14` work
out of the box, and their `CONFIG.BAT` entries double as worked
examples of per-video options. Try the verbs MOVIE (plays 001.VID
once) and REEL (loops 002.VID until a key is pressed).

## 7. Troubleshooting

- "required tool missing" - the named path does not exist; fix `TOOLSDIR`/
  `NEXFILE` or install that tool.
- "CSpect is running - close it before building" - CSpect holds `RELEASE\`
  files open; close it and rebuild.
- "expected a 320 or 256 wide PNG" - resize the named image to exactly 320 or
  256 pixels wide.
- "GAME.AKY is ... over the ... limit" - the tune is too large; shorten it or
  reduce channels in Arkos Tracker.
- "this encode cannot stream" / "cannot play at rate" - the video encoder's
  supply gate refused an infeasible encode; the message names the remedy
  (a `--stream-budget` value, a smaller shape, lower fps, or `--mono`). See
  "Video cutscenes", "Streaming, resident and direct delivery".
- "audio bytes/frame ... exceeds" - fps below the audio floor (stereo 24.40,
  mono 18.22); raise `VIDFPS` or add `--mono` to `VIDOPTS`.
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
