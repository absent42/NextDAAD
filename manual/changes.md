# What changed

Changes an author can see, newest first. If a release changed how your
game behaves, how it builds, or what the kit gives you, it is here.

## 0.3.2 - 7 August 2026

- Location pictures use the Spectrum Next's standard transparency
  magenta, and the reserved palette slot is index 255. Keep that colour
  out of your artwork and quantize to 255 colours - see
  [Graphics](graphics.md) for what the build warns about and what it
  cannot check.
- The screen no longer shows a white background before a game's first
  picture, or in any area a game has not painted.
- The kit's documentation is now a manual you read in a browser. Open
  `docs\index.html`. The old single-file guides are gone and their
  contents are spread across the pages that own each subject:
  `SETUP.md` across [Getting started](getting-started.md),
  [Graphics](graphics.md), [Audio](audio.md), [Video](video.md),
  [Customising](customising.md), [Multi-part games](multi-part-games.md),
  [DAAD V3](daad-v3.md), [Limits](reference/limits.md),
  [Symbols](reference/symbols.md) and
  [Video delivery](reference/video-delivery.md); `DIVERGENCES.md` across
  [Platform notes](platform-notes.md),
  [Known differences](known-differences.md) and
  [DAAD V3](daad-v3.md); `VIDEO-PRESETS.md` into
  [Video](video.md); `NX2-FORMAT.md` into
  [Picture format](reference/picture-format.md); and the encoder's own
  readme into [Video format](reference/video-format.md).

## 0.3.1 - 4 August 2026

A compliance release. NextDAAD now runs real DAAD databases the way the
reference interpreters do across messages, object resolution, flags and
refusals, and it accepts DAAD version 3 databases, so the standard DAAD
Ready authoring path for this target works unmodified.

**Behaviour changes are the point of this release.** A game tuned around
any of the old behaviour below - the silent `GET`, the forced continuous
listing, the old random sequence, the old convertible-noun threshold -
plays differently now.

### Breaking: cutscene audio is always stereo

The --mono encoder option is gone. Mono cost more playback time than it
saved and made no audible difference against 8-bit sound. A mono source
still needs nothing from you; it is put on both channels automatically.

If a `CONFIG.BAT` still carries --mono in `VIDOPTS` or `VIDOPTS_NNN`,
the build now stops with an unrecognised-argument error. Delete the
option; nothing replaces it.

### DAAD V3

- Version 3 databases load and run, and the kit compiles `-v3` by
  default. A version 2 database behaves exactly as it did before.
- `XMES`, second-parameter indirection and `SETAT` are implemented, as
  are the version 3 flag 53 bits. `PAUSE 0` under version 3 means "wait
  for a key". `SYNONYM` no longer marks its entry done under version 3.
- An existing version 2 game needs three checks before you trust a
  version 3 build of it - see [DAAD V3](daad-v3.md).

### Objects and messages

- `GET`, `DROP`, `WEAR`, `REMOVE`, `PUTIN` and `TAKEOUT` print their
  success messages. The objects always moved; the player was simply
  never told. `GET ALL` and `DROP ALL` were completely silent.
- Refusal messages come out in the right order across the whole family,
  so the message that appears is the one that fits. A refusal now
  performs `NEWTEXT` and aborts the rest of a compound order, so
  `GET SWORD AND KILL ORC WITH IT` no longer attacks the orc when the
  sword was refused. `OK` deliberately does not abort.
- The AUTO- family tells "there is no such object anywhere" apart from
  "that word is not an object".
- `TAKEOUT` performs the weight check it never had.
- Object names are no longer article-stripped in listings. `LISTOBJ`,
  `LISTAT`, the inventory and `LOOK` print the text as authored - "a
  pair of dungarees", not "pair of dungarees".
- Substituting a name into a message removes only a leading "a ",
  "an ", "some " or "the ", and keeps any other first word, so "rusty
  sword" stays "rusty sword". A substituted name is also truncated at
  the first ".". See [Platform notes](platform-notes.md).
- An object text with no space in it used to print nothing at all. It
  now prints.
- Abandoning a name part-way through no longer leaves the text that
  follows reading from the wrong place.
- `@` substitutes only in Spanish databases now, matching DAAD Ready's
  own escape table. In an English database `@` is an ordinary printable
  character, so a message containing `-@@-` prints `-@@-`; it used to
  eat any literal `@` an English message contained. In a Spanish
  database its capitalisation now actually happens.
- Extended object attributes are loaded in the right order. `HASAT` for
  attributes 0-7 was reading 8-15 and the other way round, which
  silently corrupted every attribute test in every game.
- A bare noun resolves against an object that carries an adjective, so
  `GET LAMP` finds a "QUAINT LAMP". A full adjective match still beats a
  partial one.
- Search priority is restored for the AUTO- family and `WHATO`. Every
  "carried" pass was really an "anywhere" pass, which could match
  objects that had never been created and let `AUTOT` take something out
  of a container the player was nowhere near.
- `WHATO` with no match clears flags 54-59 instead of leaving the
  previous object's data in them.
- `SWAP` is a raw exchange that no longer adjusts flag 1, and sets the
  referenced object. `COPYOO` sets the referenced object and does adjust
  flag 1.
- Zero-weight containers are magic bags: their contents no longer
  transmit weight.

### Listings and flow

- `LISTOBJ` and `LISTAT` honour flag 53 bit 6 - clear lists one object
  per line, set gives the continuous "a, b and c." form. The continuous
  form used to be forced. Flag 53 bit 7 is maintained on both paths, and
  an empty `LISTAT` prints SM53 alone.
- A listing no longer overwrites the referenced object.
- `ISDONE` and `ISNDONE` report everything done since the current
  process table was entered. `SKIP` and `REDO` no longer count.
- `PICTURE` and `MOVE` mark the process table done on every exit,
  including their failing ones. **One authoring pattern changes:** a
  `PROCESS` holding only a `MOVE`, tested afterwards with `ISNDONE` to
  print "I can't go in that direction", no longer prints it. Let `MOVE`
  gate the entry itself and put the message in the following entry,
  which reads the same everywhere.
- A `DOALL` that finds nothing performs `NEWTEXT` and `NOTDONE`; one
  that iterated and ran out still completes done.
- `EXIT n` with n non-zero restarts the game. It used to do nothing.
- `WINDOW n` out of range keeps the current window instead of falling
  back to window 0.
- An out-of-range location raises runtime error 1, not error 7.
- `RANDOM` and `CHANCE` use a real generator. The old one returned six
  distinct values in a repeating cycle of eight, and `CHANCE 50` fired
  62 per cent of the time. Any game that depended on the old sequence
  now differs.

### Parser and input

- `PARSE 1` re-parses the quoted section of the last order, so
  `SAY "..."` commands work - see [Platform notes](platform-notes.md).
- `INPUT stream options` switches the active window for the input and
  restores it afterwards.
- `QUIT` and `END` read a whole line at the confirmation prompt, echoed
  live, and act on ENTER. They used to act on a single keypress.
- The convertible-noun threshold is 40, not 20. **Any noun numbered
  20-39 now acts as a command when typed on its own.**

### Flags

- Flag 29 reads 129 and flag 62 reads 144. Flag 29 was never written at
  all, so a game gating its artwork on `HASAT GMODE` drew nothing.
- Flags 37 and 52 start at 0 rather than 4 and 10. Set your own limits
  in your reset process with `ABILITY`, or `LET fMaxCarr` /
  `LET fStrength`. Every corpus game and the starter already do.
- Flag 61 is cleared whenever flag 60 is written.
- Saves made before this release still load, but they carry the old
  values of flags 29, 53 and 62. Start a fresh game to pick up the
  current ones.

### Audio

- `BEEP` plays the note and the length the compiler actually emitted.
  The two parameters were being read the wrong way round, so most
  authored `BEEP`s played a wrong note or were dropped. The tone ceiling
  is 238 rather than 222, which recovers the top eight semitones.
- Sampled sound effects no longer distort while a picture is drawn.
- Two AY music symptoms remain open: distortion when all nine channels
  are driven at once, and a tune restarting at a lower tone after
  `STOPM`.

### Video

- A clip can be up to 256 MB, lifted from 16 MB, and the encoder refuses
  an over-size clip at build time with a message naming the limit -
  it used to write a file the player then refused to open. See
  [Video](video.md) section 6 and
  [Video format](reference/video-format.md).
- Shapes replace the five fixed profiles: `full`, `16:9`, `scope`,
  `classic` and `classic-wide`, plus any explicit width by height and a
  free height derived from an aspect ratio. Whether a clip plays
  resident or streams is chosen for you; direct-serve is a separate
  per-clip opt-in (`--direct` in `VIDOPTS_NNN`).
- The mid-clip pause is gone, keyframes no longer hitch, and half-rate
  clips play at their true rate.
- Sources that are not 25 fps are retimed by blending rather than by
  dropping frames, which removes the motion stutter the old method
  caused. `--retime` selects the other methods.
- The frame-rate floor for sound is 10.17 fps, down from 24.4, so a
  12.5 fps encode of a demanding clip is a real option.
- Uncompressed playback reaches 256x153 at 25 fps, and full-screen
  320x256 at 12.5 fps.
- The streaming budget is derived per clip rather than guessed, and the
  encoder reports what it chose. The kit no longer ships per-clip budget
  values.
- New: `--prefilter` for grainy sources and `--tile-slack` for
  sustained motion. Removed: offset copy and cut approximation, neither
  of which improved the picture.
- Stale-picture recovery now works, so a screen that has drifted too far
  from the source is refreshed.
- A clip stored in exactly 32 fragments on the card was falsely refused.
  The real limits are 32 fragments for a resident clip and 8 for a
  streamed or direct one.
- A cutscene that fails to open now says why on screen instead of
  silently skipping.
- Video needs a 2MB Next. A 1MB machine has too small a memory pool to
  hold or stream clips reliably.

### The kit

- New `VIDTUNE.BAT`: pick a clip, preview a segment, change the shape,
  frame rate and dither, encode and accept - the settings are written
  into `VIDOPTS_NNN` in `CONFIG.BAT`, so the next build reproduces what
  you previewed. Ships ready to run.
- Location pictures draw slightly faster.
- The "!" glyph was redrawn to match the font's stroke and baseline.

## 0.2.0 - 23 July 2026

- Cutscene video: the native NXV format and a build step that encodes
  `VIDEO\NNN.mp4` for you and caches the result. Playback with
  `GFX n 13` and `GFX n 14`.
- `videnc.exe` ships with the kit, so no Python is needed to encode a
  cutscene. ffmpeg is the only extra download video authoring wants.
- AY music is parked during a cutscene and resumes after it.
- Deleting a source no longer leaves its converted file behind in
  `RELEASE\`. A tune or picture you remove from the kit folder is
  cleared out on the next build instead of lingering on the card.
- Keyboard fixes: the symbol-shift map was off by one from F onward, and
  CAPS+2 typed a literal 2 instead of toggling caps lock.
- Font fixes: a proper ampersand and pound sign in place of the euro
  sign and apostrophe the inherited font carried.

## 0.1.0 - 20 July 2026

First release: a DAAD interpreter for the ZX Spectrum Next, with Layer 2
location graphics, tilemap text, AY music and sound effects, sampled
sound, and the authoring kit that builds an SD card image from your DSF.
