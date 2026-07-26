# videnc.py - NXV v2 video encoder

`lib/videnc.py` (the ONE canonical copy - it ships in the authoring kit
and the repo's test harness consumes it from here) encodes any video
ffmpeg can read into NextDAAD's native NXV v2 `.VID` format: a
FLIC-lineage delta format (SKIP/RUN/COPY/palette opcodes over the
Layer 2 surface, keyframes composed hidden and flipped atomically,
scene-scoped adaptive palettes) with any shape from five presets to
free heights, roughly 7:1 smaller than the old raw format. NXV v2 is
the only output; v1 files no longer play - re-encode from the original
source.

The CLI front-end is `videnc.py`; the pipeline lives beside it in
`nxv2enc.py` (encoder) and `nxv2dec.py` (the reference decoder - the
executable specification of the Z80 player, used by the encoder's own
verification pass).

## Requirements

- Python 3
- Pillow (`pip install Pillow`) - quantization and image plumbing.
- numpy (`pip install numpy`) - the delta/rate-control math.
- ffmpeg. Default: `tools\ffmpeg\bin\ffmpeg.exe` relative to the kit
  root (see `tools\README.txt` for the download). Override with
  `--ffmpeg PATH` (the repo's test harness passes its own copy).

The standalone `videnc.exe` (shipped in the kit at
`tools\videnc\videnc.exe`, built from this script with PyInstaller)
needs none of the Python stack - only ffmpeg.

## Usage

```
python lib\videnc.py INPUT OUTPUT.VID [options]

  --shape S          shape preset (full/16:9/scope/classic/classic-wide,
                     default: full) or an explicit WIDTHxHEIGHT
                     (width 256 or 320, height 1 to the mode maximum)
  --aspect A         derive a free height from a displayed aspect ratio
                     (e.g. 2.35 for cinema scope); pairs with --width
                     (default 320); overrides --shape
  --width W          Layer 2 width for --aspect (256 or 320)
  --fps N            frames per second (default: 25; floors below)
  --mono             mono audio 23325 Hz (default: stereo 15625 Hz)
  --dither           Floyd-Steinberg dither (default: no dither,
                     matching the project's PNG recipe)
  --byte-cap F       delta per-frame byte cap as a fraction of the raw
                     surface (default 0.65)
  --stream-budget F  scale the delta quality caps to fit the streaming
                     SD supply; the streaming gate's refusal message
                     names the value to pass (default 1.0)
  --direct           direct-serve preset (expert): all-literal
                     raw-equivalent encode served straight from SD -
                     strictly at-rate, see below
  --no-merge         disable the gap-merge optimization (bench fixtures
                     only - production encodes keep it on)
  --start HH:MM:SS   clip start time (ffmpeg -ss)
  --duration S       clip duration in seconds
  --report PATH      write the encode's BuildReport as JSON
  --ffmpeg PATH      ffmpeg binary override
```

Example - a 4-second 16:9 clip starting at 00:00:02:

```
python lib\videnc.py source.mp4 VIDEO\001.vid --shape 16:9 --start 00:00:02 --duration 4
```

In the kit, BUILD.BAT runs this automatically for any numeric-named
`VIDEO\NNN.mp4` (see `lib\video.bat` / `lib\video.ps1`; configured by
`VIDASPECT`/`VIDFPS`/`VIDOPTS`/`VIDOPTS_NNN` in `CONFIG.BAT`); run it
by hand for per-file control or clipping.

## Shapes

| Preset | Shape | Mode | Displayed aspect |
|---|---|---|---|
| `full` | 320x256 | 1 (320-wide) | 4:3 full screen |
| `16:9` | 320x192 | 1, letterboxed | 16:9 |
| `scope` | 320x144 | 1, letterboxed | ~2.35:1 |
| `classic` | 256x192 | 0 (256-wide) | 4:3 |
| `classic-wide` | 256x144 | 0, letterboxed | 16:9 |

Any explicit `WIDTHxHEIGHT` is also valid (height 1-192 at 256 wide,
1-256 at 320 wide), and `--aspect` derives the height from a displayed
aspect ratio, correcting for the 320-wide mode's non-square pixels
(x1.067). Sources are centre-cropped to the target aspect, never
distorted. Smaller shapes encode to visibly higher quality at the
same playback budget - see the kit's SETUP.md "Video cutscenes" for
the guidance page.

## Rate control and the supply gates

The encoder is quality-maximalist under two per-frame caps: a byte cap
(wire size) and a decode-time cap priced from silicon-measured
coefficients. It degrades gracefully (coarser thresholds, fewer
refreshed pixels) rather than truncating frames.

Three gates refuse infeasible encodes at encode time, each naming its
remedy in the error message:

- **Audio floor.** One frame may carry at most 1280 real audio bytes
  (the player's double-buffer half). Stereo needs fps >= 24.40, mono
  >= 18.22. Remedy: raise `--fps` or switch to `--mono`.
- **Streaming supply.** A file bigger than the player's resident pool
  (~1.2 MB) must stream; if its mean demand exceeds the SD supply
  rate the encode is refused with the exact `--stream-budget` that
  fits. The suggestion is one linear solve - after a large change,
  re-encode and let the gate re-check.
- **Direct-serve wire (`--direct`).** Strictly at-rate, worst-frame
  checked, no slow-playback opt-out (TIGHTEN policy, owner ruling
  2026-07-26). At 25 fps stereo the envelope tops out around 256x133;
  the refusal message prints the live at-rate menu (stereo/mono
  heights, 0.90-margin variants, and the mono-floor maximum).

`--report` writes a BuildReport JSON (shape, fps, PSNR mean/worst,
keyframes, bytes, seconds-per-MB, degradation events, binding-budget
histogram) for quality tracking.

## Format authority

The NXV v2 wire format (512-byte header, opcode set, byte values) was
FROZEN 2026-07-25 on silicon bench evidence. The authoritative header
and opcode documentation is the comment block in `src\nextdaad.inc`
(repo) with matching constants in `lib\nxv2enc.py`; `lib\nxv2dec.py`
is the executable specification of the player. Every section of the
file is an exact multiple of 512-byte SD blocks.

Audio is unsigned 8-bit PCM, stereo 15625 Hz or mono 23325 Hz with
`--mono`, full rate - no decimation. Palettes are scene-scoped
adaptive 256-colour (NR $44 write order, RRRGGGBB + expanded 9th blue
bit), refreshed by PAL opcodes when drift crosses the trigger;
quantization uses `tools\png2nx.py`'s proven recipe (PIL ADAPTIVE,
no dither by default, `--dither` for Floyd-Steinberg).

### Pixel order

Mode-0 shapes are row-linear raster order; mode-1 shapes are
column-major within the content band (the player's paint order). No
stride/gap padding is ever written to disk.

## Known limitations

- The streaming gate is a whole-clip mean criterion: a clip that
  clusters its heaviest frames tighter than the ring can absorb may
  still underrun at capacity. The gate's 0.90-utilization warning
  marks such at-capacity encodes.
- Large/long source clips decode the full frame set into memory
  before writing (fine for cutscene-length clips; not optimized for
  feature-length encodes).
