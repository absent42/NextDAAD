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
  --dither AMP       blue-noise dither amplitude, 0.0-1.0 as a
                     fraction of one quantization step (default 0.5;
                     0 = pure nearest-level snap, 1 = a full step -
                     deepest gradients, most visible pattern noise)
  --byte-cap F       delta per-frame byte cap as a fraction of the raw
                     surface (default 0.65)
  --stream-budget F  scale the delta quality caps to fit the streaming
                     SD supply. DEFAULT: derived automatically (see
                     "Automatic stream budget"); pass a value to
                     override the search outright
  --budget-target U  target mean utilization for the automatic
                     --stream-budget search (default 0.90); ignored
                     when --stream-budget is given
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
  rate the encode is refused. With the automatic budget search (the
  default) this is only reached when NO budget makes the clip
  streamable, so the remedies the message names are the ones a budget
  cannot supply: a smaller shape, a lower `--fps`, a shorter clip.
- **Direct-serve wire (`--direct`).** Strictly at-rate, worst-frame
  checked, no slow-playback opt-out (TIGHTEN policy, owner ruling
  2026-07-26). At 25 fps stereo the envelope tops out around 256x133;
  the refusal message prints the live at-rate menu (stereo/mono
  heights, 0.90-margin variants, and the mono-floor maximum).

## Automatic stream budget

`--stream-budget` is a SUPPLY CEILING, not a quality dial. Lowering it
does not "compress harder" - it hands the encoder fewer bytes per frame,
so more of the picture is deferred and everything gets worse together.
Measured on one clip with nothing but the budget varied:

| budget | utilization | PSNR mean | frames budget-bound |
|--------|-------------|-----------|---------------------|
| 0.85   | 1.00        | 25.27     | 42%                 |
| 0.70   | 0.89        | 23.83     | 66%                 |
| 0.55   | 0.74        | 22.10     | 88%                 |
| 0.40   | 0.56        | 20.11     | 92%                 |

There is exactly one right value per clip - the highest the SD wire can
carry - and it depends on the footage, so **the encoder finds it
itself**. Every encode without an explicit `--stream-budget` prints what
it chose:

```
  auto-budget: --stream-budget 0.72 -> util 0.90 (target 0.90) - 3 probes, 41.2 s
```

The value shown is the one to type if you ever want to reproduce that
file by hand.

**The target is 0.90, not 1.00, on purpose.** The supply gate measures a
whole-clip MEAN, and a mean sitting at the ceiling still contains frames
well over it: a fixture measured at mean 0.98 has a p95 frame of 1.07
and runs of up to 19 consecutive frames over budget. On hardware that
reads as banding and judder, so the search leaves margin for it.
`--budget-target` moves the line if you are re-deriving it against your
own card.

**Content-limited clips.** Sometimes utilization barely responds to the
budget, because the footage is asking for less than the cap allows - the
budget is not what is limiting it. Cutting further would starve the
picture without relieving the wire at all, so the search stops and says
so:

```
  auto-budget: --stream-budget 1.00 -> util 0.91 (target 0.90 - content-limited, no lower budget relieves the wire) - 2 probes, 6.4 s
```

**Cost.** A search costs 1 to 5 encode passes, capped, and passes after
the first are cheap (the palette solve is shared between them - it does
not depend on the budget). A clip that loads resident, or that already
fits at the full budget, costs one pass and stops.

**Overriding.** An explicit `--stream-budget` wins outright: the search
does not run, the value applies verbatim, and the supply gate checks it
exactly as before - including the at-capacity warning above 0.90, which
the automatic search never triggers.

Delta-starvation diagnostics (measurements only, no verdict):

- **Delta stats line.** Every streaming encode prints a line like
  `delta stats: budget-bound 42.4% (106/250 frames), peak 12-frame
  window 100% @f88, delta-frame PSNR p10 23.37 dB`. Budget-bound frames
  are frames whose deltas did not fit the per-frame caps, so the encoder
  spent the budget on the bands it could afford and deferred the rest;
  because bands are 4 rows of paint order, deferred bands show as stale
  horizontal strips of older content. The window figure is the worst
  concentrated run: the highest budget-bound fraction inside any
  half-second window (12 frames at 25 fps, always half a second
  whatever the `--fps`), and the frame it starts at, so you can go and
  look at that moment. The delta-frame PSNR p10 is the 10th-percentile
  PSNR over non-keyframe frames.

  **These are measurements, not a pass/fail.** There is NO automatic
  starvation warning - the encoder will not tell you when a clip is
  banded, and a high budget-bound percentage on its own does not mean
  the picture is damaged. An earlier trigger on that percentage was
  withdrawn as uncalibrated: fixture 008 measures 99.2% budget-bound
  and is visually clean on hardware, while fixture 007 measures 36.4%
  and bands visibly, so the count does not separate the two. Deferral
  SEVERITY (how much of a bound frame went unpainted, and for how long)
  is the likely signal, and it is not measured yet. Judge picture
  quality by looking at the clip.

  If a clip does band, the demand levers, cheapest first: lower
  `--dither` (the strongest one - 007 fell from 42.4% to 21.6%
  budget-bound between amplitude 0.5 and 0.0), a smaller shape or lower
  `--fps`, a calmer source cut, a higher `--stream-budget` if the
  supply gate still accepts it, or accept the visual cost when the clip
  is deliberate stress content.

`--report` writes a BuildReport JSON (shape, fps, PSNR mean/worst,
keyframes, bytes, seconds-per-MB, degradation events, binding-budget
histogram, and the starvation stats: `budget_bound_frames`,
`bound_fraction`, `burst_window_frames`, `burst_peak_fraction`,
`burst_peak_frame`, `delta_psnr_p10`, `starvation_warned` - the last is
the withdrawn trigger's retired verdict, recorded for re-derivation
work and not a quality judgement) for quality tracking. It also records
the budget the encode actually ran at and how it was arrived at:
`stream_budget`, `auto_budget` (true when derived), `auto_budget_target`,
`auto_budget_probes`, and `auto_budget_ladder` - the (budget,
utilization) pairs the search measured, in probe order. Direct-serve
reports carry the same key set with the starvation and auto-budget keys
at their defaults (an all-literal stream has no deltas to starve and no
delta budget to scale), so one parser handles both modes.

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
bit), refreshed by PAL opcodes when drift crosses the trigger.
Quantization targets are blue-noise ordered-dithered into the 9-bit
display lattice (position-deterministic 32x32 void-and-cluster tile -
temporally stable, so it feeds no churn to the delta coder); `--dither`
sets the amplitude, 0.0-1.0 of a quantization step, default 0.5.

Encoder emission constraint: palette entries whose RRRGGGBB byte
equals $FE are reserved - the player keeps Layer 2 transparency
active during video with the global transparency colour NR $14 = $FE,
and hardware transparency compares only that first palette byte (the
9th blue bit is not compared), so such entries render as transparent
holes over the blanked layer below. The encoder therefore excludes
the two colliding lattice points, display colours (255,255,146) and
(255,255,182), from its representable display lattice; palette
derivation, the nearest-level snap and all quantization targets land
on the nearest remaining lattice colour instead (blue-axis
neighbours (255,255,109) and (255,255,219)), and the wire-true
quality metrics measure the actually-displayed colour.

### Pixel order

Mode-0 shapes are row-linear raster order; mode-1 shapes are
column-major within the content band (the player's paint order). No
stride/gap padding is ever written to disk.

## Known limitations

- The streaming gate is a whole-clip mean criterion: a clip that
  clusters its heaviest frames tighter than the ring can absorb may
  still underrun at capacity. The gate's 0.90-utilization warning
  marks such at-capacity encodes. It also says nothing about picture
  quality.
- Picture quality has no automatic check at all. The delta-starvation
  stats above are reported but uncalibrated - no threshold on them
  separates banded from clean content, so nothing warns you about a
  banded encode. View the clip.
- Large/long source clips decode the full frame set into memory
  before writing (fine for cutscene-length clips; not optimized for
  feature-length encodes).
