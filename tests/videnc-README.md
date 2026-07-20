# videnc.py - open .VID encoder

`tests/videnc.py` encodes any video ffmpeg can read into a MakeVid/
playvid `.VID` file, covering all six playback formats (0-5). It exists
because MakeVid 1.77's own "autopal" (palette) encodes are broken: their
pixel slots hold raw, un-quantized RGB24 data instead of palette
indices (SP13 T2 report, "Format 4 garble" section - 256x192 RGB24 is
147456 bytes against the format's 49152-byte pixel slot, so a decoded
"frame" is only the top third of a real picture; playvid itself, this
project's interpreter, and an independent offline decode all garble the
same files identically). This encoder sidesteps MakeVid entirely.

## Requirements

- Python 3
- Pillow (`pip install Pillow`) - used for ADAPTIVE 256-colour
  quantization and the transpose-based column-major pixel reorder.
  Everything else is standard library.
- ffmpeg. Default: `tools\ffmpeg\bin\ffmpeg.exe` (this project's own
  provisioned binary, read-only). Override with `--ffmpeg PATH`.

## Usage

```
python tests\videnc.py INPUT OUTPUT.VID --format 0..5 [options]

  --start HH:MM:SS   clip start time (ffmpeg -ss)
  --duration S       clip duration in seconds
  --dither           Floyd-Steinberg dither the palette formats
                      (default: no dither, matching tools\png2nx.py's
                      recipe)
  --ffmpeg PATH       ffmpeg binary override
```

Example - encode 4 seconds starting at 00:00:02 as format 4:

```
python tests\videnc.py tools\demo-files\001.mp4 out\test.vid --format 4 --start 00:00:02 --duration 4
```

## Format table

All six formats are frame-sequential: audio block + sector-alignment
pad + [palette block, palette formats only] + pixel block, repeated
per frame, whole frames only. One sector = 512 bytes.

| fmt | size | palette | audio | pad (B) | pixels (B) | sectors | pixel order |
|---|---|---|---|---|---|---|---|
| 0 | 320x240 | yes | 1866 B stereo | 182 | 76800 | 155 | column-major |
| 1 | 320x240 | no | 1866 B stereo | 182 | 76800 | 154 | column-major |
| 2 | 256x240 | yes | 3732 B stereo | 364 | 61440 | 129 | column-major |
| 3 | 256x240 | no | 3732 B stereo | 364 | 61440 | 128 | column-major |
| 4 | 256x192 | yes | 933 B mono | 91 | 49152 | 99 | row-major |
| 5 | 256x192 | no | 933 B mono | 91 | 49152 | 98 | row-major |

Sources: `tools\ZXNextOS\src\c\DotCommands\playvid\README.TXT` (frame
sizes in sectors), `video_320x240.asm` / `video_320x240_palette.asm`
(fmt 0/1 layout, "column major order"), `video_256x240.asm` /
`_palette.asm` (fmt 2/3, cited in `.superpowers\sdd\sp13-task-3-report.md`),
`video_256x192_m.asm` / `_m_palette.asm` (fmt 4/5, "row major order",
cited in `.superpowers\sdd\sp13-task-2-report.md`).

"audio" above is bytes on disk, not samples: 1866 B stereo = 933
sample pairs/frame; 3732 B stereo = 1866 pairs/frame; 933 B mono = 933
samples/frame. Stereo samples are interleaved left-then-right (even
offset = left, odd = right - `interrupts-common.asm`'s `isr_ctc_stereo`:
`ld a,(hl) / inc l ; to odd address / out (0xf3),a ; left dac B / ld
a,(hl) / out (0xf9),a ; right dac C`).

### Frame rate

50/3 fps exactly (not 16.7) for the 240-line formats (0-3); 25 fps
exactly for the 192-line formats (4/5). Both are the video_*.asm
headers' own stated rate ("50/3 frame rate" / "50/2 frame rate" i.e.
every 2nd 50Hz VBI = 25fps), passed to ffmpeg as an exact rational
(`-r 50/3`, not a rounded decimal).

### Sample rate

The encoder derives the exact per-format audio sample rate as
`(samples/frame) * (frames/sec)`, asserted at import time to land on an
exact integer. This is NOT playvid's own documentation labels, which
are tenths-precision rounded (`VID_RATE0_X10`/`VID_RATE2_X10`/
`VID_RATE4_X10` in `src\nextdaad.inc` = 156/311/233, i.e. "~15.6/31.1/
23.3 kHz"). Re-deriving from the exact sample-count-per-frame and exact
frame rate gives:

| fmt | samples/frame | fps | exact rate | rounded label |
|---|---|---|---|---|
| 0/1 | 933 pairs | 50/3 | **15550 Hz** | ~15.6 kHz |
| 2/3 | 1866 pairs | 50/3 | **31100 Hz** | ~31.1 kHz |
| 4/5 | 933 | 25 | **23325 Hz** | ~23.3 kHz |

15550 and 23325 differ from a naive "round the label back up" reading
(15600, 23330) - the exact values are what keeps one encoded frame's
audio covering exactly one frame's worth of real playback time; 31100
happens to match its rounded label exactly (1866 * 50/3 = 31100, no
remainder). Audio is always unsigned 8-bit PCM ("u8"), silence = 128
(the unsigned zero-crossing level, not 0).

### Pixel order

- Row-major (256x192, formats 4/5): standard raster order, `for y in
  0..H-1: for x in 0..W-1`. This is Pillow's own native `tobytes()`
  order for a `P`/`L` mode image - no reordering needed.
- Column-major (320x240 and 256x240, formats 0-3): `for x in 0..W-1:
  for y in 0..H-1`. No gap/stride padding bytes are stored in the file
  - the 16-byte/column hardware addressing gap (Layer 2 mode 1's fixed
  256-byte column pitch vs 240 real rows) is a player-side addressing
  artifact, skipped by the player, never written to disk. Implemented
  via `Image.transpose(Image.Transpose.TRANSPOSE).tobytes()` (a true
  matrix transpose - verified against a hand-built 3x2 test image
  before use, and against a visual round-trip decode of an encoded
  frame, see "Validation" below), not a manual per-pixel loop.

### Palette block (formats 0/2/4)

256 entries x 2 bytes, NR $44 write order:

- byte0 = RRRGGGBB (3-3-2 posterized colour: `(r & 0xE0) | ((g>>3) &
  0x1C) | (b>>6)`).
- byte1 bit0 = the expanded 9th blue bit, bit7 (L2 priority) always 0.
  The expansion uses the Next's own 8-bit-to-9-bit hardware rule
  (`docs\zx-next-dev-guide-2022-07-15\chapter-next-palette.tex:176`:
  "least significant bit of blue is set to OR between B2 and B1"),
  applied to byte0's own 2-bit blue field: `byte1 = 1 if (byte0 & 3)
  else 0`. This is the same rule `tests\gen_vid_synth.py`'s identity
  palette and the interpreter's own `vid_identity_palette`
  (`src\video.asm`) use, generalized here to arbitrary (non-identity)
  adaptive palette entries instead of an identity mapping.

Quantization: `tools\png2nx.py`'s proven recipe (RGB -> PIL ADAPTIVE
256-colour palette, no dither by default) - `img.convert("P",
palette=Image.Palette.ADAPTIVE, colors=256, dither=Image.Dither.NONE)`.
Pass `--dither` for Floyd-Steinberg instead. Quantization runs
independently per frame (no temporal palette coherence - a deliberate
simplification; MakeVid's own broken encoder never got this far to
have an opinion on it either).

### Non-palette formats (1/3/5)

No quantization pass - every pixel is posterized directly to its own
RRRGGGBB byte (`(r & 0xE0) | ((g>>3) & 0x1C) | (b>>6)`), same formula
as the palette block's byte0 above but applied straight to the source
pixel instead of a quantized palette entry.

## Classification and self-validation

playvid classifies a `.VID` file purely by its total sector count,
walking formats in priority order 0,1,2,3,4,5 and picking the first
whose per-frame sector count evenly divides the total (README.TXT:
"classifying the video format solely based on file size in priority
order... If your video is misclassified due to it being a multiple of
the file size of another format, append a blank frame to the end").

After encoding all frames, `videnc.py`:

1. Walks the same priority order itself. If the file's total sector
   count is also evenly divisible by any EARLIER-priority format's
   sector count (a coincidental collision), it appends one silent/
   blank frame and rechecks, repeating until the collision clears.
2. Re-reads the final file size and re-runs the classifier as a
   last-resort self-check. If the verdict does not match the requested
   format, it refuses to leave the file in place and exits with an
   error - this should never trigger given step 1, but is checked
   unconditionally per the "prove it, don't assume it" project
   convention.

## Validation (this task's own test encodes)

Two 4-second clips were encoded from `tools\demo-files\001.mp4` (a
generic 854x476 h264/aac source, read-only) to prove the pipeline:

```
python tests\videnc.py tools\demo-files\001.mp4 <scratch>\test4.vid --format 4 --start 00:00:02 --duration 4
  -> 100 frames, wrote 5,068,800 B, 9,900 sectors, classifies as format 4 - OK

python tests\videnc.py tools\demo-files\001.mp4 <scratch>\test2.vid --format 2 --start 00:00:02 --duration 4
  -> 67 frames (source audio ran 1244 B short of the last frame's
     needs - auto-padded with silence, reported), wrote 4,425,216 B,
     8,643 sectors, classifies as format 2 - OK
```

Frame-0 byte structure was checked for both files:

- Audio+pad region: plausible u8 samples (128 = silence at this
  particular clip's quiet opening), pad bytes all zero.
- Palette block (offset `audio+pad`, 512 bytes): every byte1 in
  {0,1} (no stray high bits - a real defect would show byte1 values
  outside that range, or a 3-byte-per-entry stride, the MakeVid RGB24
  defect's signature).
- Pixel block: 251-252 distinct index values out of 256 possible in a
  single frame (plausible for a real 256-colour adaptive quantization
  of a busy test-card image; not the flat/garbled pattern the MakeVid
  defect produces).
- Both frame 0s were also fully decoded back to PNG (indices -> palette
  -> RGB, respecting each format's own row-/column-major order) and
  visually inspected: both show a clean, unsheared SMPTE-style test
  card with countdown clock, matching the source - confirms the
  row-major (fmt4) and column-major (fmt2) pixel paths are both
  correct, not just byte-count-correct.

## Known limitations

- Palette quantization is per-frame with no temporal coherence -
  adjacent frames' palettes are independently chosen and may not
  align, which can look like colour flicker in palette-format output
  on real hardware (the interpreter re-applies the palette every frame
  regardless, per SP13 T2/T3, so this is a content-quality trade-off,
  not a playback bug).
- `--dither` uses Pillow's Floyd-Steinberg; there is no option to match
  any other dithering an original MakeVid-era tool might have used.
- Large/long source clips will decode the full frame set into memory
  before writing (fine for the short test clips this encoder targets;
  not optimized for feature-length encodes).
