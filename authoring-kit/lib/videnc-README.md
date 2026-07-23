# videnc.py - NXV video encoder

`lib/videnc.py` (the ONE canonical copy - it ships in the authoring kit
and the repo's test harness consumes it from here) encodes any video
ffmpeg can read into NextDAAD's native NXV `.VID` format: one
parameterized container, five encoding profiles (n0-n4, see the kit's
SETUP.md "Video cutscenes" or the format spec in the repo), or `auto`
to pick the nearest pixel-aspect match. NXV is the only output - the
interim MakeVid-compatible `--legacy` encoder was removed before
anything shipped (MakeVid files are not playable by NextDAAD).

## Requirements

- Python 3
- Pillow (`pip install Pillow`) - used for ADAPTIVE 256-colour
  quantization and the transpose-based column-major pixel reorder.
  Everything else is standard library.
- ffmpeg. Default: `tools\ffmpeg\bin\ffmpeg.exe` relative to the kit
  root (see `tools\README.txt` for the download). Override with
  `--ffmpeg PATH` (the repo's test harness passes its own copy).

## Usage

```
python lib\videnc.py INPUT OUTPUT.VID [--profile n0..n4|auto] [options]

  --profile P        NXV profile (default: auto)
  --mono             mono audio (halves the audio stream)
  --no-palette       embedded RGB332 palette instead of per-frame
  --start HH:MM:SS   clip start time (ffmpeg -ss)
  --duration S       clip duration in seconds
  --dither           Floyd-Steinberg dither (default: no dither,
                      matching the project's PNG recipe)
  --ffmpeg PATH      ffmpeg binary override
```

Example - encode 4 seconds starting at 00:00:02 with the classic
256x192 profile:

```
python lib\videnc.py source.mp4 VIDEO\001.vid --profile n1 --start 00:00:02 --duration 4
```

In the kit, BUILD.BAT runs this automatically for any numeric-named
`VIDEO\NNN.mp4` (see `lib\video.bat`); run it by hand for per-file
profile control or clipping.

## NXV profiles

| Profile | Shape | fps | Cadence |
|---|---|---|---|
| n0 "cinema" | 320x256 mode-1 | 12.5 | every 4th vblank, regular |
| n1 "classic" | 256x192 mode-0 | 20 | 2-3-2-3 alternation |
| n2 "widescreen" | 256x144 mode-0 letterbox | 25 | every 2nd vblank, regular |
| n3 "widescreen XL" | 320x192 mode-1 letterbox | 16.67 | every 3rd vblank, regular |
| n4 "epic" | 320x120 mode-1 letterbox | 20 | 2-3-2-3 alternation |

The format authority is the NXV spec (repo: `docs\superpowers\specs\
2026-07-21-sp14a-native-video-design.md`) and the `NXV_OFF_*` header
layout comment in `src\nextdaad.inc`. Every section is an exact
multiple of 512-byte SD blocks; the header makes each file fully
self-describing. Audio is unsigned 8-bit PCM, stereo 15625 Hz by
default or mono 23325 Hz with `--mono`, full rate - no decimation.
`auto` picks the profile whose pixel aspect best matches the source;
`--start`/`--duration` clip; the letterbox bars cost zero file bytes
(the player renders them from its fallback colour).

### Pixel order

Mode-0 shapes (n1/n2) are row-linear raster order - Pillow's native
`tobytes()`. Mode-1 shapes (n0/n3/n4) are column-major (`for x: for
y`), implemented via `Image.transpose(Image.Transpose.TRANSPOSE)` - a
true matrix transpose, verified by round-trip decode during bring-up.
No stride/gap padding is ever written to disk.

### Palette block

256 entries x 2 bytes, NR $44 write order:

- byte0 = RRRGGGBB (3-3-2 posterized colour: `(r & 0xE0) | ((g>>3) &
  0x1C) | (b>>6)`).
- byte1 bit0 = the expanded 9th blue bit, bit7 (L2 priority) always 0.
  The expansion uses the Next's own 8-bit-to-9-bit hardware rule
  (`docs\zx-next-dev-guide-2022-07-15\chapter-next-palette.tex:176`:
  "least significant bit of blue is set to OR between B2 and B1"),
  applied to byte0's own 2-bit blue field: `byte1 = 1 if (byte0 & 3)
  else 0`. This is the same rule the interpreter's own
  `vid_identity_palette` (`src\video.asm`) uses, generalized here to
  arbitrary (non-identity) adaptive palette entries instead of an
  identity mapping.

Quantization: `tools\png2nx.py`'s proven recipe (RGB -> PIL ADAPTIVE
256-colour palette, no dither by default) - `img.convert("P",
palette=Image.Palette.ADAPTIVE, colors=256, dither=Image.Dither.NONE)`.
Pass `--dither` for Floyd-Steinberg instead. Quantization runs
independently per frame (no temporal palette coherence - a deliberate
simplification).

### --no-palette output

No quantization pass - every pixel is posterized directly to its own
RRRGGGBB byte (`(r & 0xE0) | ((g>>3) & 0x1C) | (b>>6)`), same formula
as the palette block's byte0 above but applied straight to the source
pixel instead of a quantized palette entry, and the player runs its
identity palette instead of per-frame applies.

## Known limitations

- Palette quantization is per-frame with no temporal coherence -
  adjacent frames' palettes are independently chosen and may not
  align, which can look like colour flicker in fast-changing areas
  (the interpreter double-buffers the palette apply, so this is a
  content-quality trade-off, not a playback bug).
- Large/long source clips will decode the full frame set into memory
  before writing (fine for cutscene-length clips; not optimized for
  feature-length encodes).
