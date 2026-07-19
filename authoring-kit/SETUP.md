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
`GAME.AKY`/`NNN.AKY`/`GAME.SFB`/`NNN.AYS`, any `NNN.WAV`, and `0.XMB` if your
DSF uses XMESSAGE/XMES (see section 8). Copy its contents to the root of an
SD card to play on real hardware.

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
| 9 | `PLAYFLI` | Video playback on DOS. Accepted and ignored on this target in this version - a silent no-op (a DEBUG build shows a marker). Reserved for a future video feature. |
| 10 | `PLAYFLIL` | As 9, ignored. |

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
| 3 | `GETMS` | Read mouse state into four flags starting at the first argument: `flags[n]` = buttons, `flags[n+1]` = column 0-79 (X/8), `flags[n+2]` = row 0-31 (Y/8), `flags[n+3]` = column 0-53 (X/6). |
| 4 | `GETFINEMS` | Not supported - accepted and ignored. |
| 5 | `POINTERMS` | Not supported - accepted and ignored. |
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
  `.WAV`/`GAME.SFB` files there, not `.png`/`.aks` sources).
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
root if that whole pass misses), `NNN.WAV` samples, numbered
`NNN.AYS`/`NNN.AKY` songs, `GAME.SFB`, and `0.XMB`.

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
