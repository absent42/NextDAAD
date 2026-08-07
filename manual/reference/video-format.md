# Video format - NXV and the encoder

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

This file is the reference for what every option means. For deciding
which settings a particular clip wants, see `VIDEO-PRESETS.md` in the
kit root - it routes by what kind of footage you have and what you are
seeing on screen.

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
  --retime M         how to resample a source whose own frame rate is
                     not --fps: blend (default), drop or mci. See
                     "Frame rate and retiming"
  --dither AMP       dither strength, 0.0-1.0 (default 0.5). In the
                     default offset mode: the blue-noise offset depth
                     as a fraction of one lattice quantization step
                     (0 = pure nearest-colour snap, 1 = a full step -
                     deepest gradients, most visible pattern noise).
                     In --dither-mode mixture: the fraction of each
                     pixel's quantization error the dither is asked to
                     correct (0 = no dither, 1 = the local mean
                     reproduces the source)
  --dither-mode M    dithering algorithm: offset (default) or mixture.
                     offset = one global blue-noise offset per pixel,
                     then nearest-colour; mixture = Yliluoma positional
                     mixture dithering (opt-in, see below)
  --byte-cap F       delta per-frame byte cap as a fraction of the raw
                     surface (default 0.65)
  --stream-budget F  scale the delta quality caps to fit the streaming
                     SD supply. DEFAULT: derived automatically (see
                     "Automatic stream budget"); pass a value to
                     override the search outright
  --budget-target U  target mean utilization for the automatic
                     --stream-budget search (default 0.90); ignored
                     when --stream-budget is given
  --tile-slack F     OPT-IN, default 0.0 (off): let the budget-bound
                     tile schedule take a finer WHOLE-LINE rung that
                     costs a little more streaming supply. Quoted in
                     fractions of the utilisation headroom between
                     --budget-target and the 1.00 refusal line; 1.0 is
                     the cap. See "Tile slack"
  --prefilter [F]    OPT-IN, default off: light temporal denoise before
                     scaling, given as an ffmpeg filter string. Bare
                     --prefilter means hqdn3d=2:1.5:3:2.25 (half the
                     hqdn3d defaults - conservative). Source grain is
                     delta demand the wire pays for on every frame, so
                     denoising trades a little texture for supply
                     headroom. Worth trying on grainy or noisy sources;
                     it buys nothing on --direct, where a frame costs
                     the same whatever is in it
  --kf-cadence S     refresh cadence in seconds (default 5.0, 0
                     disables): when no natural keyframe (cut,
                     dissolve, staleness, drift) has occurred within
                     the window, the encoder schedules forced-clean
                     coverage of the whole screen spread across
                     ordinary delta frames, so a long cut-less clip
                     does not drift. Costs nothing measurable at the
                     default
  --direct           direct-serve preset (expert): all-literal
                     raw-equivalent encode served straight from SD -
                     strictly at-rate, see below
  --direct-transport-factor F
                     EXPERT override of the direct gate's per-byte
                     transport factor (default 1.00; the gate's fixed
                     2.2 ms/frame transport overhead is not scaled by
                     this flag). Exists for hardware-round probe
                     encodes at a hypothesised rate. Only meaningful
                     with --direct
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

## Frame rate and retiming

The Next composites at 50 Hz, so a playback rate only stays smooth if
each encoded frame occupies a whole number of display frames. 25 fps
(two display frames each) is the encoder default and the right choice
for most titles. 12.5 fps (four each) also divides evenly and is the
one other rate that plays cleanly - it halves the motion rate but
doubles the byte and decode budget every remaining frame gets, which
is what makes full-screen uncompressed playback possible at all. Rates
that do not divide 50 beat against the composite and show it. The
playback rate is fixed by the hardware, not by the source.

Almost no source material is 25p. `23.976`, `24`, `29.97` and `30` all
have to be resampled in TIME on the way in, and how that is done is
visible:

- **drop** (nearest source frame) is what ffmpeg does by default and
  what this encoder did before. A 30 fps source loses every 6th frame,
  which lands as a 73 percent motion spike on every 5th OUTPUT frame -
  a 5 Hz stutter. A 24 fps source is worse: it gains one DUPLICATED
  frame per second (measured at a dead-regular 25-frame spacing), and a
  periodic freeze reads worse than a periodic jump.
- **blend** (the default) linearly blends the two neighbouring source
  frames, at 4x the target resolution and then scaled down. On a
  cadence-folded judder metric it cuts the periodic component by 91-97
  percent on every genuinely-30 fps source measured, and removes 24 fps
  duplicates entirely.
- **mci** (`--retime mci`, opt-in) motion-compensates instead of
  blending. It is the best method measured on slow global motion -
  pans, zooms, drifting camera - and the worst thing to point at
  non-rigid motion, where optical flow tears and it loses to plain
  blending. Try it on a locked-off pan; do not reach for it by default.
  It costs roughly 5-7 s per clip on top of the extraction.

**A source already at the target rate is not touched at all** - no
filter is inserted and the encode is byte-identical to what it was
before retiming existed. The rate comes off the same ffmpeg banner
probe that reads the source's dimensions, so detection costs nothing;
rates within 0.02 fps of the target count as the target (ffmpeg prints
the banner rate to two decimals). A source whose banner carries no
frame rate at all falls back to nearest-frame selection rather than
blending against a guess.

**Byte cost.** Nil on content that is byte-starved, which is what any
clip near the streaming supply ceiling is: there the encoder's budget,
not the content, sets the size, and blended encodes landed within +/-0.6
percent of dropped ones at an identical derived budget and utilization.
On content with headroom the blended frames genuinely carry more detail
and cost about 2.3 percent. Quality moves the right way either way:
+0.12 to +0.6 dB mean PSNR and +0.3 to +1.2 dB on the delta-frame p10.
Blending does not measurably soften the picture at these sizes - 97.7
to 100.2 percent of the source's spatial gradient survives.

The encoder reports its decision on one line, e.g.

```
  retime: source 29.97 fps -> target 25 fps, blend (framerate filter at 1280x1024)
  retime: source 25 fps already at 25 fps target - not retimed
```

In the kit, set `VIDOPTS=--retime drop` (or `VIDOPTS_NNN`) to opt a
title out. `--retime` is part of the hashed argument vector the build
caches encodes against, so changing it re-encodes that title
automatically.

## Rate control and the supply gates

The encoder is quality-maximalist under two per-frame caps: a byte cap
(wire size) and a decode-time cap priced from silicon-measured
coefficients. It degrades gracefully (coarser thresholds, fewer
refreshed pixels) rather than truncating frames.

Four gates refuse infeasible encodes at encode time, each naming its
remedy in the error message:

- **Audio floor.** One frame may carry at most 3072 real audio bytes
  (the player's per-frame audio section bound; the circular feed ring
  itself is the whole 8 KB audio bank and holds two of them at once).
  Needs fps >= 10.17. Remedy: raise `--fps`.
- **Streaming supply.** A file bigger than the player's resident pool
  (~1.2 MB) must stream; if its mean demand exceeds the SD supply
  rate the encode is refused. With the automatic budget search (the
  default) this is only reached when NO budget makes the clip
  streamable, so the remedies the message names are the ones a budget
  cannot supply: a smaller shape, a lower `--fps`, a shorter clip.
- **Direct-serve wire (`--direct`).** Strictly at-rate, worst-frame
  checked, with no slow-playback opt-out. At 25 fps stereo the
  envelope tops out around 256x153 (12.5 fps carries full-screen
  320x256); the refusal message prints the live at-rate menu (the
  at-rate height, its 0.90-margin variant, and the maximum at the
  audio floor fps).
- **Whole-file size and length.** A `.VID` may be at most 268,431,360 B
  (256 MiB) and 65535 frames, whichever binds first - the player's hot
  filemap and its 16-bit frame counters. Both bounds are checked on
  every route before a byte is written, and the refusal names the one
  it hit plus the longest clip this shape and rate can reach. Remedy:
  shorten the clip, use a smaller shape or a lower `--fps`, or split it
  across several `.VID` files played back to back.

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

## Tile slack

`--tile-slack` is the encoder's one opt-in picture knob and it is
**off by default**. Leave it alone and nothing changes.

**What it does.** When a frame's deltas do not fit the per-frame
budgets, the encoder spends what it has on whole PAINT-ORDER LINES -
rows at 256 wide, columns at 320 wide - and defers the rest, so
shortfall reads as coherent regional lag instead of scattered
patchwork. It picks the granularity per frame from a ladder of 1, 2 or
4 lines, and by default it only takes a finer rung when that rung is
FREE: no fewer bytes, no more streaming supply, no worse picture.
"No more supply" is strict, and on most content it is what stops the
finer rung being taken at all. `--tile-slack` relaxes that one test,
and only that one: it lets the schedule pay a little supply for the
one-line rung.

**What it buys.** Measured on real 320x256 footage at a pinned budget:

| clip | slack | rungs taken | stream util | local (4x4) PSNR | banding index |
|:--|--:|:--|--:|--:|--:|
| boat pan | 0.0 | 4-line x237, 2-line x10 | 0.882 | 32.02 | 0.912 |
| boat pan | 0.5 | 1-line x195, 2-line x30, 4-line x22 | 0.890 | 32.33 | 0.910 |
| church zoom | 0.0 | 4-line x205, 1-line x18 | 0.874 | 34.90 | 1.243 |
| church zoom | 0.5 | 1-line x185, 2-line x26, 4-line x24 | 0.879 | 34.91 | 1.166 |

So it is worth about a third of a dB of local PSNR on a pan and about
6% off the per-line residual spread on a zoom, for roughly 0.005-0.008
of utilisation. On quiet or already-fitting material it does nothing at
all, because there are no budget-bound frames for it to act on. **This
is content-dependent and that is the whole reason it is a per-title
setting** - set it on the clip that needs it, in `VIDOPTS_NNN`.

**Units and the cap.** The value is a fraction of the utilisation
HEADROOM the encoder holds back for you: the margin between
`--budget-target` (0.90) and the 1.00 refusal line. `1.0` spends all of
it and is the cap - a higher value is refused, not clamped, because it
is asking for margin that does not exist. In practice the useful range
is small and it SATURATES: on both clips above, 0.5 and 1.0 give the
same answer, and 0.25 is already most of the way there.

**Try 0.5 first** on a title with sustained motion, then compare
against the default and keep whichever you prefer.

**What it costs, printed.** A non-zero value prints one line:

```
  tile-slack: 0.50 of headroom (target 0.90, per-frame supply allowance 5.56%) - stream util 0.890, margin 0.110 to the 1.00 refusal line
```

With the automatic budget search running (the default) the cost lands
in one of two places and which one is content-dependent: either the
utilisation simply rises inside the margin (boat pan: budget stayed
0.40, util 0.882 -> 0.890), or the search answers by re-deriving a
lower budget and the cost becomes BYTES (church zoom: 0.57 -> 0.56,
util back down to 0.891). Watch for the second - on one demo clip
here a budget step cost 3% of the wire and the picture came out
slightly worse overall, which is exactly the trade this knob exists to
let you judge rather than have made for you.

**What it cannot do.** It cannot make the schedule split a row or a
column. Sub-line granularity was tried, shipped, and read as
displacement and tearing on real hardware; the whole-line floor is
permanent and no value of this knob reaches it. It also cannot ship an
unplayable file: an encode it pushes past the supply ceiling is refused
by the same gate as ever, with the same message.

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
a recorded field, not a quality judgement) for quality tracking. It also records
the budget the encode actually ran at and how it was arrived at:
`stream_budget`, `auto_budget` (true when derived), `auto_budget_target`,
`auto_budget_probes`, and `auto_budget_ladder` - the (budget,
utilization) pairs the search measured, in probe order. Direct-serve
reports carry the same key set with the starvation and auto-budget keys
at their defaults (an all-literal stream has no deltas to starve and no
delta budget to scale), so one parser handles both modes.

## Format authority

The NXV v2 wire format - the 512-byte header, the opcode set and the
byte values - is frozen: it is not revised between releases, so a tool
written against it stays correct. If you are writing one, in order of
usefulness: `lib\nxv2dec.py` in the kit is the executable
specification of the Z80 player, so what it does with a stream IS the
format's behaviour; `lib\nxv2enc.py`, beside it, carries the matching
constants; and the authoritative header and opcode documentation is
the comment block in `src\nextdaad.inc` in the NextDAAD repository.
Every section of the file is an exact multiple of 512-byte SD blocks.

Audio is unsigned 8-bit PCM, stereo 15625 Hz, full rate - no
decimation. A mono source is converted to stereo automatically.
Palettes are scene-scoped
adaptive 256-colour (NR $44 write order, RRRGGGBB + expanded 9th blue
bit), refreshed by PAL opcodes when drift crosses the trigger.
Quantization targets are blue-noise ordered-dithered into the 9-bit
display lattice (position-deterministic 32x32 void-and-cluster tile -
temporally stable, so it feeds no churn to the delta coder); `--dither`
sets the amplitude, 0.0-1.0 of a quantization step, default 0.5.

`--dither-mode mixture` switches the dither to YLILUOMA POSITIONAL
MIXTURE DITHERING (Joel Yliluoma, "Arbitrary-palette positional
dithering algorithm", https://bisqwit.iki.fi/story/howto/dither/jy/ -
algorithm 2): per target colour the encoder builds a 32-slot candidate
list of palette entries whose GAMMA-CORRECT mean (gamma 2.2 - light
adds linearly, 8-bit values do not) reproduces that colour, sorts it by
luminance and indexes it with the same blue-noise tile. Every decision
inside it uses the article's luminance-weighted "RGBL" colour metric
(CIEDE2000 was deliberately not used - the article reports it works
better on some pictures than others and can scatter yellow pixels).
In this mode `--dither` means the fraction of each pixel's
quantization error to correct.

It is OPT-IN, and the default encode is byte-for-byte what it was
before the feature landed. Measured across the eleven leg fixtures,
mixture dithering:

- loses 0.4-3.6 dB of per-pixel wire PSNR on every fixture;
- is SPLIT on local-mean fidelity - clearly better on Jellyfish and
  Sintel and at high amplitude generally, worse on Big Buck Bunny;
- carries a systematic per-channel mean bias the offset dither does
  not (Big Buck Bunny blue -3.1 vs -0.9 at amplitude 0.5): the RGBL
  metric discounts chroma against luma by design;
- costs up to 26% more wire bytes on colourful moving content, and
  pushed one fixture from 72% to 92% budget-bound;
- weakens two keyframe triggers - because it measures its quality
  ceiling on a fully dithered frame, po_ceil drops BELOW the achieved
  PSNR on most frames, so the drift and staleness keyframes stop
  firing.

Worth trying per title on gradient-heavy material where banding is the
complaint; measure before shipping it.

Both modes are a pure function of (x mod 32, y mod 32, source colour,
palette, amplitude): no frame index, no randomness, no error diffusion,
no dependence on neighbouring pixels' results.

Encoder emission constraint: palette entries whose RRRGGGBB byte
equals $E3 are reserved - the player keeps Layer 2 transparency
active during video with the global transparency colour NR $14 = $E3,
and hardware transparency compares only that first palette byte (the
9th blue bit is not compared), so such entries render as transparent
holes over the blanked layer below. The encoder therefore
excludes the two colliding lattice points, display colours (255,0,219)
and (255,0,255), from its representable display lattice; palette
derivation, the nearest-level snap and all quantization targets land
on the nearest remaining lattice colour instead, and the wire-true
quality metrics measure the actually-displayed colour. Nothing is
asked of the source material: near-saturated magenta in the footage
(red 238 or above, green 18 or below, blue 201 or above) is snapped
like any other value, to the nearest colour the lattice still offers.

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
