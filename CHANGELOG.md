# Changelog

All notable changes to NextDAAD are recorded here.

## v0.3.1 - unreleased

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
  were completely silent.
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
- The `@` escape's capitalisation is gated on the database language
  and fires for Spanish databases only, matching jDAAD's own gate. It
  had never fired at all before - a register clobber in the message
  seek made whether it fired depend on where the database loaded.

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
  referenced object; COPYOO sets the referenced object.
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
- The two parked AY symptoms (nine-channel distortion, and a
  post-STOPM restart at a lower tone) were instrumented and measured
  against a phase-matched fresh-boot control on the real material. No
  cause was attributed and no change was made. The measurement is
  emulator-model evidence - it excludes register and player-state
  residue inside ZEsarUX's model, and cannot speak for the analog
  audio path - so both symptoms are now hardware listening tests
  rather than open code questions.

### Compatibility

- Save format is unchanged, and saves made before this release load
  normally. They carry the old VALUES of flags 29, 53 and 62, though:
  a pre-SP16 save restores flag 29 as 0, so a loaded game will take
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

## v0.2.0 - 2026-07-23

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

## v0.1.0 - 2026-07-20

Initial release. DAAD interpreter for the ZX Spectrum Next:
all 128 condacts (CALL as a documented no-op), DDB loading and
validation, the DAAD window system, parser, process engine and object
model, Layer 2 location graphics (raw and ZX0-compressed, embedded
palettes), AY music (AKY and streamed AYS) with sound effects and
BEEP, digitised sample playback, Kempston mouse with hardware sprite pointer, boot title
screens, native multi-part games with
part-transparent saves, SAVE/LOAD/RAMSAVE, and the authoring kit
(single-click build from DSF source plus asset conversion).
