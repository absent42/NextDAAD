# Changelog

All notable changes to NextDAAD are recorded here.

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
