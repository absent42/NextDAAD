# NextDAAD - ZX Spectrum Next DAAD interpreter

DAAD text adventure interpreter for the ZX Spectrum Next, written in
Z80 assembly using the Next extended instruction set.

Project status on 18/07/2026: 
The engine boots, loads and validates a DAAD DDB from SD, and runs it - 
object model, process/DOALL dispatch, windows, printing, colour,
carrying/wearing, movement, vocabulary-driven parser (TIME, INPUT,
PARSE), file-backed save/load, Layer 2 location graphics
(PICTURE/DISPLAY), and AY audio (SFX/BEEP: music, sound effects and
speaker beeps) are implemented. 125 of the 128 condacts are
implemented; the rest (MOUSE, GFX, CALL) are stubbed pending
implementation.

## Features

- Layer 2 location graphics: 256x192 and 320x256 256-colour pictures
  from Gfx2Next files, per-picture palettes, bank-allocated picture cache, 
  and double-buffered draw
- AY audio on the Turbo Sound Next (3 PSGs, 9 channels): interrupt-driven
  Arkos AKY music playback with boot autoplay, SFX-driven songs and
  sound effects, and the classic blocking BEEP tone generator
- Digitised sample playback (NNN.WAV) over the zxnDMA, mixed with AY
  music in the background, with automatic fallback to AY sound
  effects when no sample is present
- 80 column tilemap-based 80x32 text mode driver with per-character colour 
  and a custom 80 column font
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

Not yet implemented: mouse input and EXTERN subroutines.

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
chips, nine channels) through a converted Arkos Tracker 3 AKY player
that runs in the interrupt handler. Digitised samples play through
the zxnDMA on a separate channel, in the background over the music.
Files live in the SD root next to GAME.DDB:

- GAME.AKY - title/background music, auto-played (looped) at boot if
  present
- NNN.AKY - songs selected by SFX, named by song number, 3-digit
  zero-padded (SFX 1 7 plays 001.AKY)
- GAME.SFB - the sound-effects bank (Arkos sound effects export, up
  to 2K), loaded at boot if present
- NNN.WAV - digitised sample n, 3-digit zero-padded (SFX 1 1 probes
  001.WAV before falling back to GAME.SFB). Mono 8-bit PCM RIFF WAV
  only, payload up to 49152 bytes, sample rate 3500-20000 Hz taken
  from the header - no resampling. Sample numbers 1-254 are valid;
  255 is reserved and always resolves to the AY effects bank instead.
  A DAAD Ready DOS game's SOUNDS set (max 32000 bytes per effect,
  5000-20000 Hz) already fits these limits and drops in unconverted.

Exports are address-encoded: songs must be encoded for $D800 (maximum
10208 bytes) and the effects bank for $D000. Use tools/export_audio.ps1
to convert .aks sources - a hand-run SongToAky needs
`-bin --encodingAddress 0xD800`. Songs must be Arkos 3-PSG / 9-channel
exports - the interpreter rejects any other shape at load time (the
SFX is a no-op). A composition using fewer channels inside a 9-channel
song is fine - the unused channels stay silent.

SFX first-argument/sub-command semantics (jdaad-compatible):

| SFX n sub | Effect |
|-----------|--------|
| 1, 3 | play sample/effect n once (NNN.WAV via DMA, over music; falls back to AY effect n on the third AY if no valid sample) |
| 2, 4 | as 1/3, looped - an AY effect loops only if authored looping |
| 5 | stop whichever kind - sample or AY effect - is currently active |
| 6 | play song n once - the song ends in silence |
| 7 | play song n looped |
| 8 | stop the music |

Sub-commands 3 and 4 exist because the DOS DAAD convention encodes a
rate byte ahead of the sound number for them; DRC's DRF 0.40 cannot
emit that byte inside a process, so 3 and 4 behave exactly like 1 and
2 in NextDAAD - the WAV header's own rate always applies. A game can
mix kinds freely across sample numbers: whichever of NNN.WAV or the
GAME.SFB entry is present resolves for that number.

Keep-last residency: replaying the same sample number is instant -
only the first play of a given number pays the SD read, and repeat
plays reuse the resident payload until a different number is
requested. Sample playback is DMA-driven and runs in the background
over the AKY music (audio owns the DMA channel outright); the
per-frame refeed is consumed-based, so heavy SD or Layer 2 picture
I/O cannot corrupt or clip a playing sample.

Anything else is a no-op, as is any reference to a file that is not
on the SD card. An in-game restart (QUIT confirmed, RESTART) leaves
the music and any playing sample uninterrupted by design - both are
ambience that survives restarts exactly like save/load; games change
or stop music explicitly with SFX n 7 / SFX 0 8, and stop a sample or
effect with SFX n 5. Every real exit or reset (declining END's play
again prompt, EXIT 0, a fatal error) silences everything, including
the DMA and the DAC.

BEEP takes duration and pitch, matching the classic interpreters
(jdaad-pinned): duration in centiseconds, pitch an even value 24-222
mapping the classic semitone table. Odd or out-of-range pitches and
zero durations are no-ops. BEEP blocks for its duration and plays on
the third AY. Pre-emption: an actively looping song and active sound
effects both pre-empt BEEP - a BEEP during music is dropped by
design, so use sound effects for in-music stingers. Once a play-once
tune (SFX n 6) has ended, BEEP works again.

## Building

The toolchain (not included in repo) lives in tools/ 
([sjasmplus](https://github.com/z00m128/sjasmplus), [DeZog](https://github.com/maziac/DeZog) VS Code plugin, [CSpect](https://github.com/z00m128/sjasmplus), DRC via [DAAD-READY](https://www.ngpaws.com/daadready/), [Gfx2Next](https://www.rustypixels.uk/gfx2next/), [Disark](https://julien-nevo.com/disark/), [Rasm](https://github.com/EdouardBERGE/rasm)).

- Build: powershell -File build.ps1 (add -Release for a release build,
  -Force1MB for the unexpanded-RAM test build)
- Run in CSpect: powershell -File build.ps1 -Run
- Clean: powershell -File build.ps1 -Clean
- Test DDB: powershell -File tests\build-tests.ps1 regenerates
  sd\GAME.DDB and the corrupt/oversize variants in tests\out\ (add
  -Suite to make the condact test suite DDB active - 66 checks
  covering condact semantics, parser/conjunction handling, DOALL
  nesting, save/load and audio no-op safety - or -Err4 for the
  nested-DOALL error demo; add -Aud to stage the test audio assets
  from tools\audio_assets)
- VS Code: build / run / clean tasks wrap the same script

## Authoring kit

`authoring-kit\` is a DAAD-Ready-style workflow for authors: drop in a `.DSF`
(plus optional PNGs and Arkos audio), double-click `BUILD.BAT`, and get a
ready-to-run `RELEASE\` SD-card folder with the pre-built interpreter. See
`authoring-kit\SETUP.md` for the full guide. The tools it needs (not shipped in
the repo):

- DAAD Ready (DRC compiler + PHP): https://www.ngpaws.com/daadready/
- Gfx2Next (PNG to Layer 2): https://www.rustypixels.uk/gfx2next/
- Arkos Tracker 3 (SongToAky / SongToSoundEffects): https://www.julien-nevo.com/arkostracker/index.php/download/
- CSpect (emulator): https://mdf200.itch.io/cspect

## Acknowledgments

- [Tim Gilberts](http://www.gilsoft.co.uk/) for writing the original [DAAD](https://github.com/daad-adventure-writer/daad)
- [Andres Samudio](https://elviejoarchivero.com/) of Aventuras AD for contributing DAAD to the public domain
- [Uto](https://uto.speccy.org/) for creating [DRC](https://github.com/Utodev/DRC) and [DAAD Ready](https://github.com/Utodev/DAAD-Ready) which influenced a lot of this project
- NataliaPC for creating [MSX2DAAD](https://github.com/nataliapc/msx2daad) which inspired this project
- Julien Nevo for [ArkosTracker](https://www.julien-nevo.com/arkostracker/)
- Rusty Pixels for [Gfx2Next](https://www.rustypixels.uk/gfx2next/)
- Mike Dailly for [CSpect](https://mdf200.itch.io/cspect)
- z00m for [sjasmplus](https://github.com/z00m128/sjasmplus)
- Stefan Vogt for [The Curse of Rabenstein](https://github.com/ByteProject/Rabenstein) which was used during development testing


## Disclaimer

The development of NextDAAD is largely AI agent driven.