# Changelog

All notable changes to NextDAAD are recorded here.

## v0.7.1 - 15/08/2026

- Fixed: `SVC_GETMSG` corrupted the in-RAM database when decoding a
  token-compressed message. The service held its store pointer in HL
  across the text decoder, whose token paths clobber HL - every
  decoded byte after the first token reference was written into the
  DDB's own token table instead of the staging buffer. Symptoms:
  short/stale returned text from the second fetch, the interpreter's
  own messages garbling, then `RD STACK - E9` after a handful of
  fetches. One fetch of an uncompressed message (all the v0.7.0
  fixture and the ticker example ever did) never triggered it.
  Reported from the field with a six-build isolation matrix.
- The text decoder's register contract now states the HL corruption
  explicitly, and the XBN fixture gains a six-message token-compressed
  multi-fetch regression (XMS6) with a post-fetch system-message
  print to expose any future token-table damage on screen.

## v0.7.2 - unreleased

- Fixed: the `examples/fade` XBN did not restore a picture's palette
  exactly. It snapshotted and restored 8-bit `RRRGGGBB` through NR
  $41, but Layer 2 art is loaded as 9-bit pairs through NR $44
  (`l2_palette_load`, overlay2.asm), so a restore re-derived the blue
  LSB as `(B1 OR B0)` - blue 1 collapsing to 0, blue 2/4/6 rounding up
  - and discarded the second byte's bit 7, the Layer 2 per-pixel
  priority flag. Measured over a 256-colour photographic picture: red
  and green restored bit-exact, blue 3.3% low, visible as a colour
  cast after one fade out and back. The snapshot now also reads NR $44
  per colour and the fade-in endpoint restreams 9-bit pairs; the
  interpolated steps stay 8-bit. Verified bit-exact (R/G/B ratios
  1.000) by driving FADEO/FADEI in a real game under CSpect.
  The example's prebuilt `GAME.XBN` is rebuilt (3328 bytes).
- The two-write NR $44 protocol is safe to use from the #int hook: the
  dev guide's NR $43 entry states a write to $43 resets the $44 byte
  toggle, and every palette burst in the example already writes $43
  first. The example's former "cannot be made atomic" note is
  withdrawn; the standing rule against fading while a PICTURE or
  DISPLAY draws is unchanged and still carries that hazard.
- `externs/fade` gains fn 42 and fn 43. The snapshot is taken once, at
  fade-out, so changing the picture between a fade out and a fade in
  restored the OLD picture's palette onto the new pixels - and since
  `DISPLAY 0` loads the new palette as it flips (gfx_blit), the new
  scene also appeared instantly at full brightness with no fade at
  all. `EXTERN 0 42` re-snapshots what DISPLAY just programmed,
  rebuilds the tables towards the same target colour and restreams the
  solid end, so a following fn 41 fades up to the NEW picture; call it
  in the same entry as the DISPLAY, immediately after it.
  `EXTERN 0 43` blocks until the running fade finishes, bounded at
  8*speed+32 frames, replacing a DSF flag-poll loop for the common
  case. The `active` guard moved from the top of ext_main into each
  branch - a top-level guard would have swallowed fn 43, whose job is
  to be called mid-fade. Verified under CSpect: fade out, PICTURE 5,
  DISPLAY 0, fn 42, fn 41 restores picture 5 bit-exactly against a
  plain PICTURE 5 / DISPLAY 0 baseline (R/G/B all 1.000).
- fn 42 blanks BEFORE it recomputes. DISPLAY 0 leaves the new picture
  on screen at full brightness (l2_palette_load runs immediately
  before the flip), and precalc is seven 256-entry tables with a
  multiply loop per channel - several frames. Snapshotting and
  precalculating before the blank showed the new scene for ~110ms,
  measured as a 6-frame brightness spike in the field. Order is now
  snapshot, apply the solid end, precalc, apply again so the solid
  end's transparency pins match the new art. Re-measured: no spike,
  and the restore is still bit-exact.
- The 0.7.0 notes advertised the fade example for scene changes. That
  only becomes true with fn 42; the author-facing changelog says so.
- Fixed: a picture change tore its colours across the screen. gfx_blit
  loaded the incoming palette into the Layer 2 bank that was on screen,
  byte by byte and unsynchronised to the raster, so the beam scanned
  part of a frame with the old colours and the rest with the new. It
  now builds the palette in the bank that is NOT displayed
  (PAL_L2_EDIT_SECOND) and swaps surface and palette together, the NR
  $43 write trailing NR $12 by well under a scanline. Reported in the
  field as an image flash through a fade-to-black scene change; it was
  never fade-specific - every PICTURE/DISPLAY had it.
- The display does not stay on the second bank: every tilemap palette
  write programs NR $43 with bit 2 clear (PAL_TM_FIRST and friends),
  which would drag Layer 2 back to a stale bank 1. gfx_blit refills
  bank 1 behind the live bank 2 and hands the display back once the
  two are identical - both steps invisible by construction. The
  palette rewind is factored out as gfx_pal_rewind and l2_palette_load
  gains an l2_palette_load_ctl entry taking the NR $43 value in C; the
  plain entry is byte-identical, so title_blit is untouched.
- fn 42 blanks the visible bank BEFORE reading anything. What is left
  on screen after DISPLAY 0 is scanned out for as long as the extern
  takes to blank it, so the blank must be the first thing it does: one
  256-entry burst rather than a 256-colour readback plus precalc.
  Reading the picture's colours afterwards is possible because
  gfx_blit's bank-1 refill happens to leave an identical copy in the
  non-displayed bank (snapOther / pal_other_ctl / pal_snap_ctl select
  it). That refill exists for the interpreter's own correctness, not
  for externs: the extern leans on it, the interpreter promises
  nothing, and if gfx_blit changes the extern is what gets updated. Estimated exposure drops from ~60k to ~25k
  T-states, about 19 scanlines to 8; the residual is inherent to the
  picture being displayed at all, and only a palette hold in gfx_blit
  would take it to zero. NOT verifiable on CSpect, which applies
  palette writes at frame granularity and never shows a mid-raster
  band - reported from silicon, reasoned from T-state counts.
- `externs/fade` derives its NR $43 bursts from the bank currently
  DISPLAYED (pal_edit_ctl) instead of writing a constant $10. Writing
  the constant forced the display to bank 1 for the length of every
  burst, which was harmless only while everything parked there - not
  true once a picture load or a video clip leaves bank 2 live. It also
  clobbered the sprite and ULA display-select bits, which are now
  preserved.

## v0.7.0 - 14/08/2026

- Author machine code support (XBN): a `GAME.XBN` binary beside
  `GAME.DDB` is loaded at boot into one 16K bank and executes through
  the $C000-$FFFF window under a resident trampoline. The 10-byte
  header (magic, version, EXTERN entry, #int entry, size) is validated
  at load; any reject leaves the game playing without externs, and a
  Release build never crashes on a bad file.
- `EXTERN n fn` forwards to the binary's entry for every fn code not
  claimed natively - 0, 1, 2, 5, 6, 8-15 and everything from 16 up in
  Release (3/4/7 stay XMESSAGE/XPART/XUNDONE; DEBUG builds keep 6 and
  8-14 as internal probes). The classic Z80 register contract is
  honoured on entry: A=B=param1, C=fn, HL=flags+param1,
  DE=objTable+param1*6, IX=flags base.
- `CALL lsb msb` dispatches to any address inside the loaded binary's
  extent - the classic multi-entry idiom, made window-deterministic.
  Out of range, or with no XBN loaded, it stays the documented no-op.
- A 50Hz #int hook: the frame ISR calls the binary's int entry once
  per frame, after the audio tick so music timing never waits on
  author code. Full context saved around the call; one load-and-test
  on the frame path when no hook is armed.
- Ten interpreter services behind a jump table at $BEC8, frozen from
  this release and append-only: VERSION, PUTCHAR, PUTS (full DAAD
  window semantics), FOPEN/FREAD/FWRITE/FSEEK/FCLOSE (esxDOS with the
  interpreter's card discipline), RANDOM, and GETMSG (decode a user
  message into a resident buffer - the ticker's text source). Flags
  ($A200) and the object table are read and written directly, no
  service needed; `xbn.inc` in the kit carries the whole contract.
- Two worked examples ship in the kit with PREBUILT binaries beside
  the source, so an extern can be tried with no toolchain: a message
  ticker (GETMSG + per-frame tilemap writes) and a Layer 2 fade to
  any RRRGGGBB colour and back (palette readback + snapshot restore,
  transparency-pinned so punched holes never seal over mid-fade). The
  test harness byte-compares each shipped binary against a fresh
  assembly of its source and fails on drift.
- Manual: a new externs chapter and an XBN format reference; limits
  and known-differences updated (no inline parameters after
  EXTERN/CALL - flags carry parameters; 6-byte object entries; SFX
  not author-overridable; bank state is not part of save games).
- `tests/extern.dsf` and a `-Xbn` harness leg family (reject variants,
  no-binary control, both examples) exercise the whole surface; the
  feature set is verified on real hardware (register contract, CALL
  both pages, hook cadence 1:1 at 50Hz, services, file round-trip,
  GETMSG, both examples end to end).

## v0.6.0 - 13/08/2026

- Databases are compiled for a new `NEXTDAAD` DRC target: pointers are
  file offsets rather than addresses based at $8400, so the ceiling is
  64K instead of 31744 bytes. The interpreter accepts that target only -
  a classic ZX database is refused at boot with E4 - which is what lets
  the reader drop the rebase from every text seek and condact re-seek.
  The target lives in a DRC fork until upstream carries it; the kit and
  the test harness both take DRB from there and DRF from DAAD Ready.
- The kit refuses a source using `#classic`. Caught at build time because it
  cannot be caught at boot: nothing in the compiled header distinguishes
  a classic-mode database from a DRC one.
- `CONFIG.BAT` takes a directory per tool - `DAADDIR`, `DRCDIR`, `GFXDIR`,
  `ARKOSDIR`, `CSPECTDIR`, `FFMPEGDIR`, and `VIDENCDIR`/`VIDTUNEDIR` for
  the two the kit ships. An author who already has Arkos Tracker, CSpect
  or ffmpeg installed can point at it instead of keeping a second copy
  under `TOOLSDIR`. Each is blank by default and falls under `TOOLSDIR`,
  so the single-folder layout is unchanged and the two mix freely. Arkos
  and ffmpeg accept either the install root or the subfolder holding the
  programs (`tools\` and `bin\`), since both are reasonable readings of
  where the tool is.
- The tool-path derivation moved into `lib\tools.bat`, resolved after
  `CONFIG.local.BAT` loads and called by BUILD, RUN, CLEAN and VIDTUNE.
  Those four carried diverging copies of it: `VIDTUNE.BAT` ignored
  `TOOLSDIR` entirely, and `DRCDIR` was expanded before the local
  override could move it.
- `tests/bigddb.dsf` and a `-BigDdb` harness leg compile a 49645-byte
  database and assert out of the compiled bytes that the process,
  location, connection and message tables, and the text of the highest
  message, all land past the old 31744 ceiling. `tests/machine_gate.py`
  boots one patched header per case to pin which machine nibbles are
  accepted, and the harness now refuses to stage any database that is
  not this target.

## v0.5.0 - 12/08/2026

- `INK`, `PAPER` and `BORDER` take the full 0 to 255 the database
  already carried. 0 to 15 are the classic ULA colours, unchanged. 16
  to 255 are the standard Next colour of that number in `RRRGGGBB`
  form, the same convention Layer 2 artwork uses. DRC declares all three as a generic value parameter
  checked only against 0-255, and DRB writes the byte through
  untouched, so the range was always expressible and the interpreter
  was the only thing discarding it.
- **Behaviour change:** `PAPER 8-15` renders bright where it previously
  folded to the dim hue. This is closer to the Spectrum's own BRIGHT
  semantics than the old silent mask, but an existing game using those
  values looks different.
- DEBUG resident space reclaimed to fund the above: the debug console
  now draws from the resident embedded font instead of carrying its own
  2048-byte copy of the stock DAAD charset, and the SP8 DMA prescaler
  probe and the Layer 2 bring-up test-card hook are retired, both
  having answered their questions long ago. The bare-metal isolation
  ladder and the status helpers it shares are untouched.
- `tests/palette.dsf` and a `-Palette` harness leg assert at the byte
  level that extended `INK`, `PAPER` and `BORDER` parameters reach the
  compiled database unfolded, and drive 200 distinct combinations
  against the 128-pair table so the reclaim and eviction paths execute.
- 64K of banks released to the allocator. The database reservation was
  8 banks (128K) for a database the interpreter can never address more
  than 64K of, so it is now 4. On a 1MB machine the pool grows from 14
  banks to 18, which is 29% more room for the picture cache and sampled
  audio; on a 2MB machine, from 78 to 82.
- **Behaviour change:** a `GAME.DDB` over 64K is refused at boot with
  `NextDAAD: DDB oversize - E2`. It previously loaded, with everything
  past 64K unreachable by any pointer.
- The DEBUG allocator selftest works again. Its expected free-bank
  counts still counted a bank that had been withdrawn for video use, so
  it had been failing its first check, and its verdict was the one boot
  diagnostic never replayed onto the tilemap - so the failure was
  printed where nothing could show it.
- DEBUG video-page space reclaimed: the tick-based frame-timeline
  instrument is gone - the per-phase accumulators, `vid_tl_stamp` and
  its five frame-loop call sites, the CTC ISR's tick counter, the
  LNF/LNL raster probe, and the five phase rows and TOT total from the
  report. It measured phase occupancy in video-CTC ISR ticks, a clock
  that is structurally blind to a suppressed interrupt, and the
  investigation it was built for ended by finding the instrument itself
  was the artifact. The PLAY= wall-clock bracket, which exists because
  of exactly that, and the ERR/OP/POS/PASS abort breadcrumbs remain, on
  a three-row report. 582 bytes back: the two tightest pools in the
  DEBUG image go from 49 and 21 bytes free to 308 and 344. No Release
  change - the binary is byte-identical.
- A `GAME.DDB` compiled for another computer is now refused at boot with
  `NextDAAD: DDB wrong machine - E4` instead of loading and then
  misbehaving. Ten of the twelve targets DRC can compile for - CPC, C64,
  MSX, PC, Atari ST, Amiga, PCW, CP/M, Plus/4 and jDAAD - passed the old
  version and magic-number checks unchanged, then read every text and
  process through pointers based at an address the Spectrum never used.
  Only the machine is tested; Spanish and English databases both load as
  before.

## v0.4.0 - 10/08/2026

- Games can change text font while they run. `GFX n 16` installs font
  n: 0 is the base font - the embedded table, then `FONT.CHR` over it
  if one is staged - and 1 to 9 select `FONT1.CHR` to `FONT9.CHR`.
  `PART<m>\` overrides apply per number, as they already did for
  `FONT.CHR`. The tilemap reads the glyph table live, so a switch
  restyles text already on screen with no redraw. Sub-command 16 and
  not 15, because 15 is `XSPLITSCR` on CPC and C64 and a ported game
  using it would otherwise change font instead of doing nothing.
- `MOUSE n 5` (`POINTERMS`) honours its parameter, which it previously
  accepted and discarded. Shape 0 is the base pointer, 1 to 9 select
  `POINTER1.SPR` to `POINTER9.SPR`. Selecting the shape already
  installed skips the card read but still re-uploads the pattern and
  re-arms it, so the documented `POINTERMS` then `SHOWMS` sequence
  keeps its guarantee. The hotspot set by `DELTAXMS` and `DELTAYMS` is
  not touched by a shape change.
- The built-in mouse pointer is a conventional arrow cursor in place of
  the solid diagonal triangle, and is now held as a pristine copy
  separate from the live upload buffer, so `MOUSE 0 5` can restore it
  after a numbered shape has overwritten it.
- A missing or wrong-size font or pointer file stays a silent no-op:
  whatever is installed remains and the game plays on.
- The kit stages `FONT1.CHR` to `FONT9.CHR` and `POINTER1.SPR` to
  `POINTER9.SPR`, converts `IMAGES\POINTER.png` and `IMAGES\POINTER1.png`
  to `POINTER9.png` with gfx2next, and converts a kit-root `FONT.ch8`
  or `FONT1.ch8` to `FONT9.ch8` with `fontconv.ps1`. A ready-made
  `.CHR` or `.SPR` still wins over a converted source of the same
  number.
- `fontconv.ps1` gains `-Base`, which pads a 768-byte classic charset
  against a font you supply rather than the kit default, so a second
  font keeps the glyphs you defined in the first.
- The build now fails when a converted pointer is not exactly 256
  bytes instead of staging it. A 32x32 source produced 1024 bytes at
  exit 0, which the interpreter then rejected silently, so the author
  saw no error from either end.
- Deleting a numbered font or pointer source no longer leaves its
  converted file behind in `RELEASE\`.
- A failure inside the multi-part build loop returns exit code 1. It
  printed the error and stopped, but reported success to anything
  checking the exit code.
- The video player's DMA transfers can now be interrupted by the audio
  ISR instead of blocking it (interrupt-controller-guarded, DI
  brackets removed). Verified on hardware; no user-visible behaviour
  change beyond steadier audio timing during video playback.
- Sampled effects (`SFX n 1` / `SFX n 2`) now play on either of two
  independent hardware channels, mixed together and both centred, so
  two effects can sound at once. Auto-allocation prefers the channel
  already caching the number, then an idle channel, then steals a
  one-shot over a loop (oldest first); a channel can be reserved
  outright with the new sub-commands 11-14 (play once/looped, pinned
  to channel 1 or 2) and released with 15/16 or the existing 5 (now
  the documented superset: stops both sampled channels and the AY
  effect, releasing both reservations). `SFX 255` still always plays
  from the AY bank and never reserves a channel.
- A sampled effect's length is no longer bounded by the old 1 MB
  payload ceiling or by free memory at all. Files up to 24K per
  channel stage into a fixed window and replay for free on every
  re-trigger; larger files stream from the card, and a re-trigger on
  the channel still holding the file reuses what that channel has open
  instead of searching the card again, so a repeat play costs only a
  window refill. Streamed effects have a brief last-sample hold rather
  than silence at a looping effect's seam. A file split across more
  than 8 SD card fragments is refused, the same ceiling streamed video
  already uses - defragment the card.
- The recommended WAV sample rate is now 15625 Hz, which divides the
  hardware's own timing clock exactly on six of the eight video modes.
  16000 Hz - what existing NextDAAD samples use - remains fully
  supported: the clock varies by video mode and 16000 rarely divides it
  exactly, so it plays a little sharp on most modes, up to about 0.7%
  in the worst case and inaudible in practice; the supported range is
  unchanged at 3500-20000 Hz. Re-triggering an effect re-derives its
  pitch from the video mode active at that moment, so a mode change
  between triggers no longer leaves it playing at the old mode's pitch.

## v0.3.2 - 07/08/2026

- Location pictures can have holes. The reserved palette index moved to
  255: paint the Spectrum Next's standard transparency magenta,
  #FF00FF, into that slot and pixels drawn with it show the text layer
  through. Quantize to 255 colours (indices 0-254) and leave slot 255
  unused when you do not want transparency - the kit converts the PNG
  you supply as-is, it does not re-quantize. Uncompressed
  location art and title screens are audited after conversion and
  warned about; COMPRESS=1 output cannot be checked, because a
  compressed file has no readable palette.
- The screen no longer shows a white background before a game's first
  picture, or in any area a game has not painted. The tilemap was
  filling those cells with white paper while claiming to make them
  transparent.
- The authoring kit's documentation is now a generated HTML manual at
  `authoring-kit\docs\`, written as Markdown in `manual\` and built by
  `scripts\build_manual.py`. The five stand-alone guides are gone and
  their content redistributed: `SETUP.md` across getting-started,
  graphics, audio, video, customising, multi-part-games, daad-v3,
  reference/limits, reference/symbols and reference/video-delivery;
  `DIVERGENCES.md` across platform-notes, known-differences and
  daad-v3; `VIDEO-PRESETS.md` into video; `NX2-FORMAT.md` into
  reference/picture-format; `lib\videnc-README.md` into
  reference/video-format. Dropped rather than moved: DIVERGENCES
  section 7 (the reference-interpreter defect table) and section 8
  (provenance). Older entries below that name a deleted file refer to
  it under its old name; the mapping above is where its content now
  lives.

## v0.3.1 - 04/08/2026

DAAD compliance sweep. NextDAAD now executes real DAAD databases with
reference-correct behaviour across messages, object resolution, flags
and refusal semantics, and accepts DAAD V3 databases so the standard
DAAD-READY ZX Next authoring path works unmodified. Correctness only;
no new features beyond V3.

Three long-standing questions were settled by scripted measurement of
the original ZX Spectrum 48K interpreter rather than by argument: the
convertible-noun threshold, the QUIT/END confirmation input model, and
the PARSE 1 rule. Where NextDAAD deliberately still differs from the
reference interpreters, the reasons are now written down for authors
in `authoring-kit/DIVERGENCES.md`.

Reference divergence rulings: where the two reference interpreters
disagree with each other, three cases were settled rather than left
open. Flag 50 (the DOALL object) stays a flat global as msx2daad has
it, so jDAAD's per-level save/restore across PROCESS is the deviation
- do not carry flag 50 across a PROCESS call. COPYOO keeps jDAAD's
flag-1 adjustment, below. PUTIN/TAKEOUT's composite spacing took
neither reference wholesale: msx2daad's leading space, jDAAD's absent
trailing one.

### Breaking change: mono cutscene audio is gone

`--mono` no longer exists. Cutscene audio is stereo, always. Mono cost
more playback time than it saved and made no audible difference
against 8-bit sound, so it was not worth keeping. A mono source still
needs nothing from you - the encoder puts it on both channels
automatically, as it always did.

If a game or a `CONFIG.BAT` still carries `--mono` in `VIDOPTS` or
`VIDOPTS_NNN`, the build now stops on it with an unrecognised-argument
error from the encoder. Delete the option; nothing replaces it.

### Video

- A video file can now be up to 256 MB, lifted from 16 MB. An
  uncompressed clip goes from about fifteen seconds to about four
  minutes at full screen; a compressed clip is limited instead by a
  frame count worth roughly 43 minutes at 25 fps. The encoder checks
  both before it writes anything, so an over-size clip is refused at
  build time with a message naming the limit and the longest clip
  your shape and frame rate can reach - it used to write a file the
  player then refused to open.
- The mid-clip pause is gone. A long clip with no cuts used to hold
  the picture still for about a sixth of a second every few seconds,
  while the whole screen was refreshed at once. That refresh is now
  spread across ordinary frames, so nothing stops. `--kf-cadence
  SECONDS` (default 5, 0 disables) still sets how often it happens,
  and still costs nothing measurable at the default.
- Half-rate clips play at their true rate. A 12.5 fps streamed clip
  ran slightly slow, with the audio buffer running dry underneath it.
  Both are fixed, and the encoder now allows for what the slower rate
  costs when it sizes a clip to the card.
- Keyframes no longer hitch: keyframe bursts are paced to fit inside
  the frame period at every budget, removing the once-per-keyframe
  stutter on streamed clips.
- The audio frame-rate floor is lower: 10.17 fps, down from 24.4, at
  no extra memory cost. Half-rate encodes of demanding clips are a
  real option now - 12.5 fps doubles the byte and decode budget per
  frame, and divides the 50 Hz display evenly so playback cadence
  stays smooth.
- Uncompressed (direct) playback got faster: the at-rate ceiling
  grows from 256x133 to 256x153 at 25 fps, and full-screen 320x256 at
  12.5 fps now plays - pixel-perfect video at the full display size
  for content that delta compression handles badly.
- Sources that are not 25 fps (most footage: 23.976/24/29.97/30) are
  now retimed by blending instead of dropping frames, removing the
  motion stutter the old method caused. Automatic when the source
  rate differs from the target; `--retime drop` restores the old
  behaviour, `--retime mci` selects motion-compensated interpolation
  for slow pans. Genuine 25 fps sources are untouched. Note: on
  uncompressed (direct) encodes the blend's mixed frames are
  faithfully visible; `--retime drop` or `mci` may look better there.
- `--prefilter` (opt-in, off by default): a light denoise before
  scaling, for grainy or noisy sources. Grain is detail the
  compressed route pays for on every single frame, so giving up a
  little of it buys back room for everything else in the picture.
  Bare `--prefilter` uses a conservative setting; it buys nothing on
  an uncompressed encode, where a frame costs the same whatever is
  in it.
- Removed: `--ocopy` (offset copy) and `--approx-cuts` (cut
  approximation). Neither improved the picture, and offset copy made
  it worse.
- Stale-picture recovery now works: the checks that should force a
  keyframe when the picture has drifted too far from the source were
  structurally unable to fire; they now trigger on genuinely broken
  screens without disturbing clips that were already acceptable.
- Streamed auto-budgets are derived slightly more conservatively, so
  at-capacity clips keep a safety margin against stutter.
- `--tile-slack 0..1` (default 0): lets the delta scheduler spend a
  bounded slice of the supply margin on finer-grained updates - a
  per-clip quality/margin trade for sustained-motion content.

### Fixes

- Object names are no longer article-stripped when they are listed.
  LISTOBJ, LISTAT, the inventory and LOOK print the object text exactly
  as authored - "a pair of dungarees", not "pair of dungarees" -
  matching DAAD Ready's own ZX Next interpreter and both reference
  interpreters. The strip was being applied on every path instead of
  only to message substitution.
- Substituting an object name into a message now removes only a leading
  "a ", "an ", "some " or "the ", whatever the case, and keeps any
  other first word. So "rusty sword" substitutes as "rusty sword"
  rather than "sword". jDAAD removes the first word whatever it is;
  NextDAAD deliberately does not, because it destroys descriptive text -
  in one surveyed game it was deleting the character's name from every
  object described as "'Alapetia'; a wig maker". The trade is that a
  game written for the old behaviour, with object texts like "my
  wallet", will now read "the my wallet" in a message that supplies its
  own article. See `authoring-kit/DIVERGENCES.md`.
- An object text with no space in it used to print nothing at all, in
  listings as well as substitutions. It now prints.
- The capitalising `@` escape, which applies to Spanish databases only,
  now capitalises the first character of a name that carries no
  article, not just one that followed a stripped article.
- Abandoning an object name part-way through a compressed token no
  longer leaks a level of the text reader's stack, which could leave
  the following text reading from the wrong place. This affected the
  existing "." truncation rule as well as the new article scan.
- PICTURE and MOVE now mark the process table done, matching both
  reference interpreters. PICTURE marked it nowhere at all; MOVE marked
  it only when it found a connection. Both now mark it on every exit,
  including their failing ones. This is visible to `ISDONE`/`ISNDONE`
  only when the condact under test is the first Action in its table.
  One authoring pattern changes: a `PROCESS` whose table is just a
  `MOVE`, tested afterwards with `ISNDONE` to print "I can't go in that
  direction", no longer prints it - the failed MOVE now marks the table
  done, so the `ISNDONE` fails and the entry stops. It behaved that way
  on both references all along. Test the movement directly instead:
  MOVE is itself a condition, so let it gate the entry and put the
  message in the following entry, which reads the same on every
  interpreter. The same applies to PICTURE, which still fails its own
  entry when no art loads.
- Flags 37 (objects carried) and 52 (strength) are no longer
  pre-initialised to 4 and 10 and now start at 0, matching both
  references - neither pre-initialises them, and both write the pair
  only in `ABILITY`. Set your own limits in your RESET process with
  `ABILITY`, or with `LET fMaxCarr` / `LET fStrength`. Every corpus game
  and `STARTER.DSF` already does, so a game started from the kit is
  unaffected; a game that set neither could carry four objects here and
  none anywhere else, and now carries none everywhere.
- Compiling with DRC's debug flag no longer breaks the game. The
  markers DRC writes into the process tables for the ZEsarUX debugger
  were being read as `NEWTEXT`, so every marker silently threw away the
  rest of a multi-command order - a debug build stopped obeying commands
  half way through, with no error and nothing on screen to explain it.
  NextDAAD now steps over them, so a debug build plays exactly like a
  normal one. Every other DAAD interpreter still has this bug; see
  `DIVERGENCES.md`.
- `ISDONE` and `ISNDONE` now report everything done since the current
  process table was entered, which is what both reference interpreters
  do. Previously they reported only the last sub-process that ended, so
  an `ISDONE` with no `PROCESS` in front of it read a stale result from
  whichever table happened to finish last. `SKIP` and `REDO` no longer
  count as actions for this, again matching both references. The common
  idiom - `PROCESS n` followed by `ISDONE` - behaves exactly as before.
- The `@` message escape now substitutes the referenced object's name
  only in Spanish databases, matching jDAAD and DAAD Ready's own escape
  table, where `@` is "the same as the underscore, but the article has
  its first letter uppercased - only works for Spanish interpreter". In
  an English database `@` is an ordinary printable character, so a
  message containing `-@@-` now prints `-@@-`. It used to substitute in
  every language, which silently ate any literal `@` an English message
  contained. The underscore is unaffected and still substitutes in
  every language.
- Sampled sound effects no longer distort while a picture is being
  drawn. An effect playing across a location picture or any screen
  redraw came out buzzy and rough - a grating edge on the sound that
  cleared the moment the picture finished. It affected every game
  using sampled effects, on every build, from the day sampled effects
  were added.
- Location pictures draw slightly faster, out of the same work.
- A video file stored in exactly 32 fragments on the SD card was
  falsely refused. The real limits are now enforced and documented:
  resident clips up to 32 fragments, streamed and direct clips up to
  8 (defragment the card or re-copy the file if a clip is refused).
- The '!' glyph did not read as an exclamation mark; redrawn to match
  the font's stroke and baseline (kit default.chr updated to match).
- A video that fails to open now says why on screen (VID FILE?/VID
  FMT?/VID NOBANK2/VID SIZE?/VID FRAG?) instead of silently skipping
  the cutscene.

### DAAD V3

- Version 3 databases load and run. Header version 2 or 3 is accepted;
  everything version-specific is gated on the loaded header, so a
  version 2 database behaves exactly as it did before.
- V3 condacts implemented: XMES (120), INDIR (122, second-parameter
  indirection - the one DRC emits automatically and cannot be avoided
  in a V3 database) and SETAT (124, set/clear/toggle an attribute
  bit). Under version 2 all three still raise runtime error 5, as
  both references do.
- V3 flag 53 bits: bit 0 (DOALL found no objects, set at DOALL entry
  and cleared on the first object found), bit 1 (alternative attribute
  flag bank at 91 rather than 59, honoured by HASAT, HASNAT and SETAT
  alike), bit 4 (a preposition preceded noun 1), bit 5 (an
  unrecognised word followed the verb). Bit 2 (suppress Spanish
  enclitic pronouns) has nothing to suppress here - see below.
- `PAUSE 0` under V3 means "wait for a key" (the GETKEY keyword), not
  "wait 256 frames".
- `SYNONYM` no longer marks the entry DONE under V3, and still does
  under V2 - the DAAD platform split, with Z80 on the marking side.
- The authoring kit now compiles `-v3` by default, matching DAAD
  Ready's own ZX Next build script, so a DSF authored elsewhere in the
  DAAD ecosystem for this target builds here in the dialect its author
  compiled against. Both DRF sites carry the flag - the main game and
  each `PART<n>\` part - because every part of a multi-part game must
  be the same dialect. An existing version 2 game needs three checks
  before you trust a V3 build of it (SYNONYM done-marking, `PAUSE 0`,
  and flag 53 bit 1): migration notes in
  `authoring-kit/DIVERGENCES.md` section 6, "Moving your game to V3".
  The bundled starter game passes all three and compiles
  byte-identically in either dialect apart from its version byte. To
  stay on version 2, remove `-v3` from `lib\ddb.bat` and `BUILD.BAT`.

### Object interaction and messages

- GET, DROP, WEAR, REMOVE, PUTIN and TAKEOUT print their success
  messages (SM36/SM37/SM38/SM39, and PUTIN/TAKEOUT's composite
  SM44/SM45/SM51 output). The objects always moved; the player was
  simply never told. Most visible with GET ALL and DROP ALL, which
  were completely silent. The composite's final form is the leading
  message, a space, the container's name, then SM51 with no space
  before it - so a stock SM51 of "." renders "The hat is in the old
  box." and not "... the old box ." The same form covers AUTOP, AUTOT
  and TAKEOUT's two refusal messages, which share the helper.
- Refusal check order restored across the whole family, so the right
  refusal message appears: DROP of an object lying at the player's
  location answers SM49 rather than "I don't have one of those"; WEAR
  tests location, worn and carried before wearability, which makes
  SM49 reachable at all; REMOVE produces SM23 ("I'm not wearing one of
  those") where it previously used SM50 for both cases; GET tests
  weight before the hands-full count, which decides whether a GET ALL
  against an over-strength load stops dead or keeps going.
- A refusal now performs NEWTEXT, so it aborts the rest of a compound
  order. `GET SWORD AND KILL ORC WITH IT` no longer attacks the orc
  when the sword was refused. OK (condact 23) deliberately does not -
  a successful entry ending in OK keeps the rest of the order alive.
- The AUTO- family distinguishes "there is no such object anywhere"
  from "that word is not an object": SM8 is printed for the latter, as
  both references do.
- TAKEOUT performs the weight check it never had.
- Substituted object names are truncated at the first "." (both
  references do this), so one `/OTX` entry can serve as both a short
  name and a longer description. Plain LISTOBJ/LISTAT output is not
  truncated.
- In a Spanish database, `@`'s capitalisation now actually happens. A
  register clobber in the message seek meant it had never fired at
  all, and whether the branch was even reached depended on where the
  database happened to load. (What `@` does per language is covered
  under Fixes, above.)

### Object resolution

- Extended object attribute bytes are loaded in the right order.
  `HASAT n` for attributes 0-7 was reading attributes 8-15 and vice
  versa, silently corrupting every attribute test in every game.
- A bare noun resolves against an object that carries an adjective:
  `GET LAMP` finds a "QUAINT LAMP". A full adjective match still wins
  over a partial one, so disambiguation between "RUSTY SWORD" and
  "SHINY SWORD" is preserved.
- Search priority restored for the whole AUTO- family and WHATO. The
  "anywhere" sentinel collided with the object-carried location value,
  so every "carried" pass was really an "anywhere" pass and could
  match objects that had never been created. This also made AUTOT able
  to take an object out of a container the player was nowhere near.
- WHATO with no match clears flags 54-59 instead of leaving the
  previous object's data in them.
- SWAP is a raw exchange that no longer adjusts flag 1 (swapping two
  carried objects used to leave it two too low) and sets the
  referenced object; COPYOO sets the referenced object and, unlike
  SWAP, does adjust flag 1 - it is a one-way move that can take an
  object out of the player's hands, so the carried count owes it a
  decrement.
- Zero-weight containers are magic bags: their contents no longer
  transmit weight.

### Listing and display

- LISTOBJ and LISTAT honour flag 53 bit 6: clear (the default) lists
  one object per line, set gives the continuous "a, b and c." form.
  The continuous form used to be forced, which is not DAAD's default.
- Flag 53 bit 7 ("objects were listed") is maintained on both the
  LISTOBJ and the LISTAT path, set when objects were listed and
  cleared when none were.
- An empty LISTAT prints SM53 alone, with no extra newline.
- A listing no longer overwrites the referenced object. Any LISTOBJ or
  LISTAT silently re-pointed flags 51 and 54-59 at the last object it
  listed.

### Flow control

- A DOALL that finds no matching object performs NEWTEXT and NOTDONE.
  A DOALL that iterated and then ran out still completes DONE - the
  two cases are distinct and were merged.
- `EXIT n` with n non-zero reinitialises windows, flags and objects
  and restarts the game. It used to do nothing at all.
- `WINDOW n` with n out of range keeps the current window instead of
  masking to window 0.
- An out-of-range location raises runtime error 1 ("invalid location")
  rather than error 7 ("bad message").
- MOUSE sub-commands 4-7 are implemented: GETFINEMS (fine position
  into three flags), POINTERMS (re-upload the built-in pointer into
  sprite slot 0), DELTAXMS and DELTAYMS (the pointer hotspot offset -
  not movement deltas, despite the symbol names). RESETMS also clears
  the hotspot now.
- RANDOM and CHANCE use a real 16-bit xorshift (period 65535) with
  uniform output scaling. The old generator was degenerate: it could
  return only six distinct values in a repeating cycle of eight, and
  CHANCE 50 fired 62 per cent of the time. Any game whose behaviour
  depended on the old sequence will now differ.

### Parser and input

- `PARSE 1` re-parses the quoted section of the last order, so
  `SAY "..."` style commands work. The rule was measured on the
  original interpreter and no reference implements it correctly:
  whether a quoted section exists decides whether the sentence flags
  are refilled, and what it contains decides the condition.
- `INPUT stream options` switches the active window for the duration
  of the input and restores it afterwards.
- QUIT and END read a LINE at the confirmation prompt - the reply is
  echoed live and nothing happens until ENTER. NextDAAD used to act on
  a single keypress; measurement of the original settled it against
  NextDAAD, which was the outlier of three.
- The convertible-noun threshold is 40, not 20: a bare noun with a
  vocabulary id below 40 acts as a verb. Measured on the original.
  Behaviour change worth knowing about - any noun numbered 20-39 now
  acts as a command when typed on its own.

### Flags

- Flag 29 (graphics flags) reads 129 - bit 7 because Layer 2 location
  graphics exist, bit 0 because the MOUSE condact is implemented. It
  was never written at all, so a period game gating its picture
  drawing on `HASAT GMODE` drew nothing on a machine whose headline
  feature is Layer 2 artwork.
- Flag 62 (screen mode) reads 144 at initialisation.
- Flag 61 is cleared whenever flag 60 is written, matching INKEY's
  documented pair behaviour.

### Audio

- BEEP plays the note and the length the compiler actually emitted.
  DRC deliberately swaps BEEP's two parameters for ZX targets, so the
  interpreter was reading the tone as a duration and the duration as a
  pitch: most authored BEEPs played a wrong note or were silently
  dropped.
- BEEP's tone ceiling is 238 rather than 222, which recovers the top
  eight semitones of octave 8 - the range DRC can actually emit.
- Two AY music symptoms are still open and not fixed here: distortion
  when all nine channels are driven at once, and a tune restarting at
  a lower tone after STOPM. Both were investigated for this release
  without a cause being found.

### Compatibility

- Save format is unchanged, and saves made before this release load
  normally. They carry the old VALUES of flags 29, 53 and 62, though:
  an older save restores flag 29 as 0, so a loaded game will take
  the no-graphics branch of `HASAT GMODE` until something rewrites the
  flag. Start a fresh game to pick up the new flag values.
- Behaviour changes are the point of this release. A game tuned around
  any of the old behaviour above - the silent GET, the forced
  continuous listing, the old RNG sequence, the 20 convertible-noun
  threshold - will play differently.

### Authoring kit

- New `DIVERGENCES.md`: the register of places where NextDAAD
  deliberately differs from the reference DAAD interpreters, with what
  each reference does, what NextDAAD does and why, and what it means
  for a DSF. Also lists the reference-interpreter defects found while
  adjudicating, so a difference against one particular reference is
  not mistaken for a NextDAAD fault.
- New `VIDEO-PRESETS.md`: how to choose video settings for your own
  footage. Which of the two routes suits which kind of clip, six
  ready-made blocks of settings to copy, a step-by-step ladder to
  work down when a clip bands, how much card space a clip costs and
  how long one can run, and what each on-screen video error means.
- New `VIDTUNE.BAT`: a video tuning window. Pick a clip, preview a
  segment of it, change the shape, frame rate, dither and the rest,
  encode and accept - the settings are written into `VIDOPTS_NNN` in
  `CONFIG.BAT`, so the next build reproduces exactly what you
  previewed. Ships ready to run; no Python needed.
- `SETUP.md`: MOUSE sub-command table updated for the full 0-7 set,
  BEEP parameter order and tone range documented.

## v0.3.0 - unreleased

### Video

- L2 snapshot/restore: the game's visible picture surface and its
  palette are snapshotted at video start and restored automatically at
  exit, while the screen is still hidden. The post-video redraw
  convention is retired - games no longer need PICTURE/DISPLAY (or the
  starter's PROCESS 7) after a cutscene; CLS+RESTART remains a
  scene-change choice. Costs 3 (256x192 game) or 5 (320x256) pool
  banks per session, 0 with L2 hidden; reservation failure refuses
  the video (VID NOBANK2). Back surface is undefined across a video.
- NXV v2 replaces NXV v1 outright - v1 files no longer play, re-encode
  from source. FLIC-lineage delta format (SKIP/RUN/COPY/palette opcodes
  over the Layer 2 surface, keyframes composed hidden and flipped
  atomically, scene-scoped adaptive palettes), roughly 7:1 smaller
  files. Format frozen 2026-07-25 on silicon bench evidence.
- Shapes replace the five fixed profiles: presets full 320x256,
  16:9 320x192, scope 320x144, classic 256x192, classic-wide 256x144,
  plus any explicit WIDTHxHEIGHT and --aspect free-height derivation
  (true 2.35:1 scope). fps is free (default 25) above the audio floors:
  stereo 24.40, mono 18.22.
- Delivery unified and automatic: resident (file fits the bank pool),
  ring-streamed (prefetch ring of pool banks, files bigger than the
  pool), or direct-served (encoder-hinted uncompressed, straight from
  SD). All strictly at true rate; direct-serve gate is unconditional
  (TIGHTEN ruling 2026-07-26, no slow-playback opt-out).
- Encoder: quality-maximalist dual-budget rate control at
  silicon-measured prices; encode-time supply gates refuse infeasible
  encodes with named remedies (at-rate direct envelope, smaller shape,
  lower fps).
- Streaming budget is derived per clip, not guessed: --stream-budget
  now defaults to an automatic search for the highest budget the SD
  wire carries, targeting 0.90 mean utilization (margin under the 1.00
  refusal line, because a mean at the ceiling still bands and judders),
  and the encoder reports what it chose. An explicit --stream-budget
  still overrides it. The kit no longer ships per-clip budget values.
- Exit-order fix: Layer 2 hidden across the mode restore - kills the
  exit flash when a mode-0 video ends inside a 320-wide game.
- Kit: VIDPROFILE replaced by VIDASPECT (preset/WIDTHxHEIGHT/aspect
  number; old name maps for one release) plus VIDFPS, VIDOPTS and
  per-video VIDOPTS_NNN; shape-quality guidance in SETUP.md; demo
  clips re-encoded (001 full, 002 16:9).
- Breaking hardware requirement: video needs a 2MB Next (the standard
  fit on issue 2 boards and later) - a 1MB machine has too small a
  pool to hold or stream clips reliably.
- Fixed: multi-PSG AKY tunes left PSG 3 unparked on video entry,
  an audible frozen tone under video. Entry now parks all three PSGs.

## v0.2.0 - 23/07/2026

Cutscene video playback, hardware-measured performance work,
and a self-contained authoring pipeline.

### Video

- New native NXV video format. One parameterized
  container: self-describing header, 512-byte-block-aligned sections,
  per-frame adaptive palettes, full-rate audio (stereo 15625 Hz or
  mono 23325 Hz), play-once and loop.
- Five encoding profiles, all verified inside their frame budgets on
  real hardware: N0 cinema 320x256@12.5, N1 classic 256x192@20,
  N2 widescreen 256x144@25, N3 widescreen XL 320x192@16.67,
  N4 epic 320x120@20.
- Video player: raw SD streaming (persistent CMD18 window, no esxDOS
  in the hot path), double-buffered per-frame palette apply (palette
  sparkle eliminated), presentation isolation (tilemap hidden and
  fallback black around the video), cheap loop restart (no file
  reopen, header read skipped on rewind).
- AY music is parked cleanly during video playback and resumes after.
- videnc.py encoder: NXV output with profile auto-selection,
  center-crop, clipping, mono and no-palette options.

### Performance

- Codebase-wide optimization: engine dispatch (MUL-based, ~96T saved   per condact on hot paths), overlay routine slimming, alternate-register-set residency
  in the video gap path, unrolled transfer runs with computed entry.
- Silicon-measured throughout: the SD SPI sustained floor
  (~22T/byte effective) was established by emulator-vs-hardware
  differential measurement and every profile budget derives from it.

### Fixes

- Keyboard symbol-shift map off-by-one (comma read as period, and
  every symbol from F onward shifted) - an escaped backslash
  assembled as two bytes.
- CAPS+2 caps-lock now toggles instead of typing a literal 2.
- Font glyphs: proper ampersand at $26 and pound sterling at $60
  (genuine 48K ROM shapes; the inherited Spanish-lineage DAAD font
  carried a euro sign and apostrophe there).
- Layer 2 exit state after 256x192 video in a 320x256 game left to
  the game redraw convention (see SETUP.md - PICTURE/DISPLAY or
  CLS+RESTART after a cutscene).

### Authoring kit

- mp4-to-NXV cutscene pipeline in BUILD.BAT: drop VIDEO\NNN.mp4 in
  and the build encodes it (cached beside the source, re-encoded only
  when the source changes; VIDPROFILE knob, auto by default).
- videnc.exe shipped with the kit - no Python needed;
  ffmpeg is the only extra download for video authoring.
- Starter template demonstrates both post-video restore conventions.
- Stale-clean fix: removed audio sources no longer leave their old
  WAV staged in RELEASE.
- Kit interpreter republished (plays NXV).

## v0.1.0 - 20/07/2026

Initial release. DAAD interpreter for the ZX Spectrum Next:
all 128 condacts (CALL as a documented no-op), DDB loading and
validation, the DAAD window system, parser, process engine and object
model, Layer 2 location graphics (raw and ZX0-compressed, embedded
palettes), AY music (AKY and streamed AYS) with sound effects and
BEEP, digitised sample playback, Kempston mouse with hardware sprite pointer, boot title
screens, native multi-part games with
part-transparent saves, SAVE/LOAD/RAMSAVE, and the authoring kit
(single-click build from DSF source plus asset conversion).
