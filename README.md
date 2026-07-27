# NextDAAD - ZX Spectrum Next DAAD interpreter

DAAD text adventure interpreter for the ZX Spectrum Next, written in
Z80 assembly using the Next extended instruction set.

Project status (v0.3.0): 
The engine boots, loads and validates a DAAD DDB from SD, and runs it - 
object model, process/DOALL dispatch, windows, printing, colour,
carrying/wearing, movement, vocabulary-driven parser (TIME, INPUT,
PARSE), file-backed save/load, Layer 2 location graphics
(PICTURE/DISPLAY/GFX), AY audio (SFX/BEEP: music with streamed-song
support, sound effects and speaker beeps), digitised sample playback
bounded by available RAM, full-screen video cutscene playback (GFX
13/14, aliased SFX 9/10), mouse input with a hardware sprite
pointer (MOUSE), boot title screens, and native multi-part games
(EXTERN n 4) are implemented. All 128 condacts are handled, but CALL
is a documented no-op.

## Features

- Layer 2 location graphics: 256x192 and 320x256 256-colour pictures
  from Gfx2Next files, per-picture palettes, bank-allocated picture cache, 
  double-buffered draw, and DMA-accelerated surface copies
- AY audio on the Turbo Sound Next (3 PSGs, 9 channels): interrupt-driven
  Arkos AKY music playback with boot autoplay, SFX-driven songs and
  sound effects, the classic blocking BEEP tone generator, and
  streamed AYS songs (per-frame AY-register-delta streams read from
  SD) for tunes too large for the fixed AKY song slot
- Digitised sample playback (NNN.WAV) through a per-sample CTC/DAC
  feed, bounded by available RAM rather than a fixed size (banked
  across allocated 16K RAM banks, with a reserved floor so a sample
  always has room), mixed with AY music in the background, with
  automatic fallback to AY sound effects when no sample is present
- Direct Layer 2 surface control (GFX): copy/swap/clear the picture
  plane's front and back buffers on demand
- Video cutscenes (GFX 13/14, aliased as the classic SFX 9/10 PLAYFLI/
  PLAYFLIL): native NXV v2 delta-video .VID playback, shapes from
  full-screen 320x256@25 down to free heights, 256 colours with
  scene-scoped adaptive palettes, full-rate DAC audio (stereo 15625 Hz
  or mono 23325 Hz), resident/ring-streamed/direct-served delivery
  chosen automatically, play-once or loop-until-keypress,
  PARTn-shadowed like other assets
- Mouse input (MOUSE) via the Next's Kempston mouse ports, with a
  hardware sprite pointer (sub-commands 0-3; buttons read
  jdaad-compatible: idle 0, left 1, right 2, middle 4)
- Boot title screens: ship DAAD.NX2 or DAAD.NXI next to GAME.DDB and
  it displays at boot over the autoplay music until a keypress - no
  source changes
- Native multi-part games: EXTERN n 4 switches to GAMEn.DDB with
  flags and objects carried, part-transparent SAVE/LOAD and RAMSAVE
  (a save from any part loads anywhere and switches automatically),
  and per-part assets in PARTn\ directories with the game root as a
  shared pool
- 80 column tilemap-based 80x32 text mode driver with per-character colour 
  and a custom 80 column font
- Custom fonts and mouse pointers: drop FONT.CHR (standard DAAD
  2048-byte charset) or POINTER.SPR (16x16 sprite pattern) next to
  GAME.DDB - loaded at boot, per-part via PARTn\, no source changes
- DDB loading and validation from SD card (esxDOS), with header/size
  error handling
- Full RAM detection and 8K bank allocator across the Next's extended
  memory map
- SAVE/LOAD and RAMSAVE/RAMLOAD to esxDOS .SAV files, with failure handling
- The DAAD window system (8 windows: geometry, colour, cursor
  save/restore, scrolling, More... paging)
- DDB text reader: token expansion, message/system-message lookup,
  escape codes
- Vocabulary lookup and a logical-sentence parser driving PARSE,
  including conjunction-separated multi-command input (get lamp and
  drop hat)
- Process engine: PRO table dispatch, PROCESS/DOALL, REDO/SKIP/RESTART,
  condact argument indirection
- Object model: carrying, wearing, weight/capacity limits, containers
  (PUTIN/TAKEOUT), AUTOG/AUTOD/AUTOW/AUTOR, object placement and
  lookup
- Keyboard decode layer and line input editor with cursor movement,
  timeouts and shift handling
- Word-wrapping print pipeline that buffers a pending word across
  window edges
- Debug build with an on-screen diagnostic console (frame counter,
  stub markers, register dumps) and SLD debug data for DeZog
  source-level debugging
- Authoring Kit: DAAD-READY like single click tool for building 
  NextDAAD game releases with pre-built interpreter, format converted 
  images, AY audio files etc

## Location graphics

Pictures are pure [Gfx2Next](https://github.com/benbaker76/Gfx2Next)
`-pal-embed` output: a 512-byte palette (256 two-byte 9-bit entries)
followed by raw 8-bit pixels. Files live in the SD root next to
GAME.DDB, named by picture number, 3-digit zero-padded:

- NNN.NX2 - 320 pixels wide (320x256 mode), any height up to 256
- NNN.NXI - 256 pixels wide (256x192 mode), any height up to 192

Either file may also be ZX0-compressed: Gfx2Next's `-zx0` option
appends `.zx0` to the output name, and the interpreter probes those
first - NNN.NX2.ZX0 (8.3 synonym NNN.N2Z), NNN.NX2, NNN.NXI.ZX0
(NNN.NXZ), then NNN.NXI. A whole raw file compressed in one pass
(e.g. with z88dk-zx0) works just as well as Gfx2Next's own output.
Height is derived from the (decompressed) file size, and shorter
pictures are drawn top-aligned with the rest of the screen left
transparent, so text windows below the art show through.

The two modes differ in screen coverage. 320-wide pictures (NX2)
cover the full screen, border area included. 256-wide pictures (NXI)
display over the classic paper area only, inset by the border on
every side - the art occupies tile rows 4 to 4+height/8 of the 80x32
text grid - so games using 256-wide art should lay out their text
windows the classic way, inside the paper area.

Text colours are safe by construction: text renders on the tilemap
layer with its own fixed 16-colour classic ULA palette, while picture
palettes are written only to the Layer 2 palette. All 256 slots
are usable for art, with one reservation:

- Palette index 254 is the transparency index. The interpreter forces
  its colour to the global transparent colour after every palette
  load, and any art palette entry whose colour would collide with it
  is shifted by one blue LSB (imperceptible). Art should simply avoid
  drawing with index 254; Gfx2Next output does not need any special
  treatment otherwise.

### Title screens

A game shipping DAAD.NX2 (320-wide) or DAAD.NXI (256-wide) next to
GAME.DDB gets a title screen at cold boot: the picture displays over
the boot-autoplay music (GAME.AYS/AKY, if present) until any key is
pressed, then the game begins. The file rules are identical to
location art - same formats, same ZX0-compressed variants
(DAAD.NX2.ZX0/N2Z probed first), same converter. A release build
showing a title suppresses its version banner so the title is the
first thing seen; with no DAAD.* file, boot is unchanged. The title
lives in the game root only - it shows once per boot and is never
re-shown by a multi-part switch.

### The classic look

To author a game with the classic bordered Spectrum screen, use
256-wide NXI art (it displays over the paper area) and lay the text
windows inside the paper area of the 80x32 text grid, which spans
tile rows 4-27 and columns 8-71 - for example WINDOW/WINAT 4 8/
WINSIZE 24 64 for the full classic screen. Set the surround with
BORDER 0-7, which on NextDAAD colours everything outside the art and
text: the ULA layer is off, so the interpreter maps BORDER onto the
Next's global fallback colour instead. 320-wide NX2 art covers the
border area entirely, so BORDER only matters for classic-layout
games.

## Audio

AY music and sound effects play on the Next's Turbo Sound (three AY
chips, nine channels). Two song formats are supported: a converted
Arkos Tracker 3 AKY player, resident in a fixed RAM slot, for small
songs; and AYS, a NextDAAD-native per-frame AY-register-delta stream
read from SD, for songs too large for the AKY slot - both run in the
interrupt handler. Digitised samples play through a per-sample
CTC/DAC feed on a separate channel, in the background over whichever
song format is active. Files live in the SD root next to GAME.DDB:

- GAME.AKY - title/background music, auto-played (looped) at boot if
  present and no GAME.AYS is found
- GAME.AYS - streamed title/background music, probed before GAME.AKY
  at boot
- NNN.AKY - songs selected by SFX, named by song number, 3-digit
  zero-padded (SFX 1 7 plays 001.AKY if no 001.AYS is present)
- NNN.AYS - a streamed song, probed before the matching NNN.AKY
- GAME.SFB - the sound-effects bank (Arkos sound effects export, up
  to 2K), loaded at boot if present
- NNN.WAV - digitised sample n, 3-digit zero-padded (SFX 1 1 probes
  001.WAV before falling back to GAME.SFB). Mono 8-bit PCM RIFF WAV
  only, sample rate 3500-20000 Hz taken from the header - no
  resampling. Payload size is bounded by available RAM rather than a
  fixed limit: samples are allocated across 16K RAM banks (not one
  fixed slot), with a reserved floor so a sample up to 48K always has
  room regardless of other RAM pressure, up to a 1MB sanity ceiling.
  Sample numbers 1-254 are valid; 255 is reserved and always resolves
  to the AY effects bank instead. A DAAD Ready DOS game's SOUNDS set
  (max 32000 bytes per effect, 5000-20000 Hz) already fits these
  limits and drops in unconverted.

AKY exports are address-encoded: songs must be encoded for $D800
(maximum 10208 bytes) and the effects bank for $D000. Use
tools/export_audio.ps1 to convert .aks sources - a hand-run SongToAky
needs `-bin --encodingAddress 0xD800`. Songs must be Arkos 3-PSG /
9-channel exports - the interpreter rejects any other shape at load
time (the SFX is a no-op). A composition using fewer channels inside
a 9-channel song is fine - the unused channels stay silent. AYS
streams have no fixed-slot limit (bounded by available RAM, like
samples); the authoring kit converts an Arkos .aks source to AYS via
Arkos Tracker 3's SongToYm - see authoring-kit/SETUP.md for the
export path.

SFX first-argument/sub-command semantics (jdaad-compatible):

| SFX n sub | Effect |
|-----------|--------|
| 1, 3 | play sample/effect n once (NNN.WAV via the CTC/DAC feed, over music; falls back to AY effect n on the third AY if no valid sample) |
| 2, 4 | as 1/3, looped - an AY effect loops only if authored looping |
| 5 | stop whichever kind - sample or AY effect - is currently active |
| 6 | play song n once - whichever of NNN.AYS or NNN.AKY resolves; the song ends in silence |
| 7 | play song n looped - whichever of NNN.AYS or NNN.AKY resolves |
| 8 | stop the music - AKY or AYS, whichever is playing |
| 9 | play video n once (NNN.VID) - the classic PLAYFLI symbol, identical to GFX n 13 |
| 10 | as 9, looped until a key is pressed - PLAYFLIL, identical to GFX n 14 |

Sub-commands 3 and 4 exist because the DOS DAAD convention encodes a
rate byte ahead of the sound number for them; DRC's DRF 0.40 cannot
emit that byte inside a process, so 3 and 4 behave exactly like 1 and
2 in NextDAAD - the WAV header's own rate always applies. A game can
mix kinds freely across sample numbers: whichever of NNN.WAV or the
GAME.SFB entry is present resolves for that number.

Keep-last residency: replaying the same sample number is instant -
only the first play of a given number pays the SD read, and repeat
plays reuse the resident payload until a different number is
requested. Sample playback runs in the background over whichever
song format is active (AKY or AYS): each sample byte is delivered by
a CTC-timed interrupt from a ring buffer refilled in the main loop,
so heavy SD or Layer 2 picture I/O cannot corrupt or clip a playing
sample. Song number 255 with sub-command 6 or 7 plays the game's
boot theme (GAME.AYS/GAME.AKY) from the game root, in any part of a
multi-part game.

Anything else is a no-op, as is any reference to a file that is not
on the SD card, or an AY effect number beyond GAME.SFB's own loaded
effect count. An in-game restart (QUIT confirmed, RESTART) leaves
the music and any playing sample uninterrupted by design - both are
ambience that survives restarts exactly like save/load; games change
or stop music explicitly with SFX n 7 / SFX 0 8, and stop a sample or
effect with SFX n 5. Every real exit or reset (declining END's play
again prompt, EXIT 0, a fatal error) silences everything, including
the CTC sample feed and the DAC.

BEEP takes duration and pitch, matching the classic interpreters
(jdaad-pinned): duration in centiseconds, pitch an even value 24-222
mapping the classic semitone table. Odd or out-of-range pitches and
zero durations are no-ops. BEEP blocks for its duration and plays on
the third AY. Pre-emption: an actively looping song and active sound
effects both pre-empt BEEP - a BEEP during music is dropped by
design, so use sound effects for in-music stingers. Once a play-once
tune (SFX n 6) has ended, BEEP works again.

Compatibility note: In CSpect, playing digitised sampled sound at the 
same time as AY music currently causes the AY music to slow down. 
This does not happen on actual ZX Spectrum Next hardware though.

## Video cutscenes

`GFX n 13` plays video `NNN.VID` once; `GFX n 14` loops it until a key
is pressed. Both are also reachable through the classic DOS DAAD
symbols `SFX n 9` (PLAYFLI) and `SFX n 10` (PLAYFLIL) - see the SFX
table above. `NNN.VID` lives in the SD root next to GAME.DDB, 3-digit
zero-padded like every other numbered asset; `PARTn\NNN.VID` shadows it
per part.

`.VID` files are NextDAAD's native NXV v2 format: a self-describing
container (a real header, nothing to select at the DSF level) carrying
a FLIC-lineage delta video stream - SKIP/RUN/COPY/palette opcodes over
the Layer 2 surface, keyframes composed on the hidden buffer and
flipped atomically, scene-scoped adaptive 256-colour palettes - at
roughly 7:1 smaller than raw. Any shape is a valid encode: five presets
(full 320x256, 16:9 320x192, scope 320x144, classic 256x192,
classic-wide 256x144) plus free heights down to a single line, at any
fps (default 25) above the audio floors (stereo 24.40, mono 18.22).

Audio is full-rate unsigned 8-bit PCM - stereo at 15625 Hz by default,
mono at 23325 Hz - played through the Next's DAC ports by a CTC-timed
interrupt feed. Frames present at vblank; delivery is automatic per
file: at or below the resident bank pool (~1.2 MB) the clip plays from
RAM, above it the clip streams through a prefetch ring of pool banks,
and encoder-hinted direct-serve clips play uncompressed straight from
SD - all strictly at true rate. Streaming reads raw SD card blocks
(CMD18 multiple-block reads over the file's own cluster map), so the
whole pipeline runs without OS calls while a video plays. The tilemap
text layer is hidden and letterbox bars render black for the duration;
both restore on exit. Video needs a 2MB Next. Files should be
reasonably contiguous on card - a file in more than 32 fragments
refuses to play (defragment or re-copy the card). NXV is 50Hz-designed;
a 60Hz display gets slower playback and audio popping, an accepted
limitation.

Video playback is a full-screen takeover, like DISPLAY, and the player
puts everything back itself: register state, the visible picture
surface and its palette are all restored when the video ends (the
front surface and Layer 2 first palette are snapshotted into reserved
pool banks at start - a video refuses with VID NOBANK2 if the pool
cannot cover the reservation; the hidden back surface is undefined
afterwards). No post-video redraw is needed. Game audio is likewise
handled automatically - a playing sample is stopped (not resumed), and
AY music is frozen in place and resumes on its own the instant the
cutscene ends; no author action is needed either way.

Encoding: `authoring-kit/lib/videnc.py` (Python 3 + Pillow + numpy +
ffmpeg) is the one canonical encoder - quality-maximalist delta
encoding under silicon-measured rate control, with encode-time supply
gates that refuse an unstreamable or off-rate file and name the remedy
(proven on hardware). The kit's BUILD.BAT runs it automatically for any
`VIDEO\NNN.mp4` (preferring the standalone `videnc.exe` build of the
same encoder when present - shipped with the kit, no Python needed).
See `authoring-kit/SETUP.md`'s "Video cutscenes" section and
`authoring-kit/lib/videnc-README.md`.

## Custom fonts and mouse pointer

Both follow the title-screen pattern: drop a file next to GAME.DDB,
no source changes; a missing file means the built-in default, a
wrong-sized file is ignored. Both load at boot and re-probe at a
multi-part switch, so PARTn\ copies give each part its own look.

- FONT.CHR - the whole game renders in a custom font: a standard
  DAAD charset, exactly 2048 bytes (256 glyphs x 8 bytes, 1bpp).
  Every DAAD font tool (CH82CHR, jDAADFontMaker, GCS - and Damien
  Guard's classic fonts through CH82CHR) emits this format directly;
  the authoring kit's fontconv converts classic 768-byte ZX
  charsets, padding the rest from the built-in font. One rule: glyph
  32 (space) must stay blank - the renderer relies on it.
- POINTER.SPR - replaces the arrow mouse pointer: a raw 16x16
  hardware-sprite pattern, exactly 256 bytes, one byte per pixel
  read as RRRGGGBB colour, value $E3 = transparent. Any Next sprite
  editor emits the format; the kit stages a ready-made file as-is.

FONT2.CHR and upward, and the MOUSE POINTERMS sub-command, are
reserved for a future runtime-switching feature - one font and one
pointer shape at a time for now.

## EXTERN and MALUVA

DAAD's EXTERN condact takes a vector number as its second argument,
selecting one of 16 dispatch slots. NextDAAD implements three:

- Vector 3 - XMESSAGE (XMES): prints text stored externally in
  0.XMB, a file DRC writes alongside GAME.DDB at compile time and
  which belongs in the SD root next to it. The text is read from
  disk and printed through the same token expansion, word-wrap and
  More... paging as any DDB message - indistinguishable from native
  text. A missing or unreadable 0.XMB is a silent no-op - like a
  missing picture or audio asset elsewhere, the game simply
  continues.
- Vector 4 - XPART: switches the running game to part n (GAMEn.DDB),
  carrying the flags and object locations across - the multi-part
  game mechanism. The authoring kit's SETUP.md has the full
  multi-part guide, including the PARTn asset directories and the
  part-aware SAVE/LOAD behaviour.
- Vector 7 - XUNDONE: clears the current action's done state, for
  SYNONYM-style entries that should not count as a completed turn.

Every other vector is a safe no-op. Upstream DRC has deprecated the
rest of classic MALUVA - XPICTURE, XSAVE, XLOAD, XBEEP,
XSPEED, XNEXTCLS, XNEXTRST - in favour of native engine features, and
NextDAAD covers the same ground natively: PICTURE/DISPLAY for
pictures, SAVE/LOAD for game state, EXIT for resets, and SFX for
sound.

Two things are deliberately unsupported. DRB's `-X` (`dumpToXMB`)
compiler flag, which would route all game text through XMB rather
than just explicit XMESSAGE calls, is not implemented. And a
hand-written EXTERN n 3 is reserved - fn 3 is XMESSAGE's own 3-byte
encoding (offset low, 3, offset high), and the engine always consumes
a matching third stream byte whenever it sees that shape, so any
other use of literal fn 3 will misalign the condacts that follow it.
The bundled DRC toolchain is DRF 0.40 + DRB 0.36.

## Authoring kit

`authoring-kit\` is a DAAD-Ready-style workflow for authors: drop in a `.DSF`
(plus optional PNGs and Arkos audio), double-click `BUILD.BAT`, and get a
ready-to-run `RELEASE\` SD-card folder with the pre-compiled interpreter. See
`authoring-kit\SETUP.md` for the full guide. The tools it needs (not shipped in
the repo):

- DAAD Ready (DRC compiler + PHP): https://www.ngpaws.com/daadready/
- Gfx2Next (PNG to Layer 2): https://www.rustypixels.uk/gfx2next/
- Arkos Tracker 3 (SongToAky / SongToSoundEffects / SongToYm for
  streamed AYS songs): https://www.julien-nevo.com/arkostracker/index.php/download/
- CSpect (emulator): https://mdf200.itch.io/cspect

The latest version of the authoring kit can be downloaded from the
Github [releases](https://github.com/absent42/NextDAAD/releases) and contains 
only the parts of the repository that an author needs to build a NextDAAD 
game.

## Interpreter Building

If you wish to complile your own version of the interpreter the toolchain (not included in repo) lives in tools/ 
([sjasmplus](https://github.com/z00m128/sjasmplus), [DeZog](https://github.com/maziac/DeZog) VS Code plugin, [CSpect](https://mdf200.itch.io/cspect), DRC via [DAAD-READY](https://www.ngpaws.com/daadready/), [Gfx2Next](https://www.rustypixels.uk/gfx2next/), [Disark](https://julien-nevo.com/disark/), [Rasm](https://github.com/EdouardBERGE/rasm)).

- Build: powershell -File build.ps1 (add -Release for a release build,
  -Force1MB for the unexpanded-RAM test build)
- Run in CSpect: powershell -File build.ps1 -Run
- Clean: powershell -File build.ps1 -Clean
- Test DDB: powershell -File tests\build-tests.ps1 regenerates
  sd\GAME.DDB and the corrupt/oversize variants in tests\out\ (add
  -Suite to make the condact test suite DDB active - 80 checks
  covering condact semantics, parser/conjunction handling, DOALL
  nesting, save/load, GFX/MOUSE/CALL, XMESSAGE and audio no-op
  safety - or -Err4 for the nested-DOALL error demo; add -Rab or -UU
  to compile and stage a corpus game (Rabenstein or Urban Upstart)
  instead; -Part stages the two-part switching fixture; -Title stages
  the title-screen art; add -Aud to stage the test audio assets from
  tools\audio_assets)
- VS Code: build / run / clean tasks wrap the same script

## Troubleshooting

Boot and runtime failures show a legible message on the tilemap (row 0,
white on magenta), plus a border colour flash as a secondary signal. All
of these halt the interpreter; power-cycle or reset to retry.

- `NextDAAD: DDB missing - E1` (red border) - no GAME.DDB on the SD card,
  or the SD/esxDOS filesystem itself could not be reached
- `NextDAAD: DDB oversize - E2` (magenta border) - GAME.DDB is bigger
  than the 128K interpreter limit
- `NextDAAD: DDB bad header - E3` (yellow border) - GAME.DDB exists but
  failed validation (wrong version or corrupt)
- `NextDAAD: RUNTIME ERROR - E<n>` (magenta border) - the engine hit an
  internal fault while running the game (n = 0-8, see src/errors.asm)
- `NextDAAD: RD STACK - E9` (red border) - internal text-reader stack
  overflow; should not happen with a correctly compiled DDB

## Acknowledgments

- [Tim Gilberts](http://www.gilsoft.co.uk/) for writing the original [DAAD](https://github.com/daad-adventure-writer/daad)
- [Andres Samudio](https://elviejoarchivero.com/) of Aventuras AD for contributing DAAD to the public domain
- [Uto](https://uto.speccy.org/) for creating [DRC](https://github.com/Utodev/DRC) and [DAAD Ready](https://github.com/Utodev/DAAD-Ready) which influenced a lot of this project
- NataliaPC for creating [MSX2DAAD](https://github.com/nataliapc/msx2daad) which inspired this project
- Julien Nevo for [ArkosTracker](https://www.julien-nevo.com/arkostracker/)
- em00k for [playwav32](https://github.com/em00k/playwav32) which informed the sample sound playback method
- Rusty Pixels for [Gfx2Next](https://www.rustypixels.uk/gfx2next/)
- Mike Dailly for [CSpect](https://mdf200.itch.io/cspect)
- z00m for [sjasmplus](https://github.com/z00m128/sjasmplus)
- Stefan Vogt for [The Curse of Rabenstein](https://github.com/ByteProject/Rabenstein) which was used during development testing


## Disclaimer

The development of NextDAAD is largely AI agent driven.