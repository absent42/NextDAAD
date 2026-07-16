# NextDAAD - ZX Spectrum Next DAAD interpreter

DAAD text adventure interpreter for the ZX Spectrum Next, written in
Z80 assembly using the Next extended instruction set.

Project status on 16/07/2026: 
The engine boots, loads and validates a DAAD DDB from SD, and runs it - 
object model, process/DOALL dispatch, windows, printing, colour,
carrying/wearing, movement, vocabulary-driven parser (TIME, INPUT,
PARSE), file-backed save/load, and Layer 2 location graphics
(PICTURE/DISPLAY) are implemented. 124 of the 128 condacts are
implemented; the rest (SFX, BEEP, MOUSE, GFX, CALL) are stubbed
pending implementation.

## Features

- DDB loading and validation from SD card (esxDOS), with header/size
  error handling
- Full RAM detection and 8K bank allocator across the Next's extended
  memory map
- Tilemap-based 80x32 text mode driver with per-character colour and a
  custom font
- The DAAD window system (8 windows: geometry, colour, cursor
  save/restore, scrolling, More... paging)
- DDB text reader: token expansion, message/system-message lookup,
  escape codes
- Process engine: PRO table dispatch, PROCESS/DOALL, REDO/SKIP/RESTART,
  condact argument indirection
- Object model: carrying, wearing, weight/capacity limits, containers
  (PUTIN/TAKEOUT), AUTOG/AUTOD/AUTOW/AUTOR, object placement and
  lookup
- Keyboard decode layer and line input editor with cursor movement,
  timeouts and shift handling
- Word-wrapping print pipeline that buffers a pending word across
  window edges
- Vocabulary lookup and a logical-sentence parser driving PARSE,
  including conjunction-separated multi-command input (get lamp and
  drop hat)
- SAVE/LOAD and RAMSAVE/RAMLOAD to esxDOS .SAV files, with failure handling
- Layer 2 location graphics: 256x192 and 320x256 256-colour pictures
  from Gfx2Next files, per-picture palettes, real PICTURE/DISPLAY
  condacts, bank-allocated picture cache
- Debug build with an on-screen diagnostic console (frame counter,
  stub markers, register dumps) and SLD debug data for DeZog
  source-level debugging

Not yet implemented: sampled and AY sound effects, AY music playback,
mouse input, EXTERN subroutines, and compressed (.zx0) picture
loading.

## Location graphics

Pictures are pure [Gfx2Next](https://github.com/benbaker76/Gfx2Next)
`-pal-embed` output: a 512-byte palette (256 two-byte 9-bit entries)
followed by raw 8-bit pixels. Files live in the SD root next to
GAME.DDB, named by picture number, 3-digit zero-padded:

- NNN.NX2 - 320 pixels wide (320x256 mode), any height up to 256
- NNN.NXI - 256 pixels wide (256x192 mode), any height up to 192

For each PICTURE the interpreter tries NNN.NX2 first, then NNN.NXI.
Height is derived from the file size, and shorter pictures are drawn
top-aligned with the rest of the screen left transparent, so text
windows below the art show through.

Text colours are safe by construction: text renders on the tilemap
layer with its own fixed 16-colour classic ULA palette, while picture
palettes are written only to the Layer 2 palette. Unlike interpreters
that share the first 16 palette slots between graphics and text (DAAD
Ready's /s shift), a picture can never recolour text - all 256 slots
are usable for art, with one reservation:

- Palette index 254 is the transparency index. The interpreter forces
  its colour to the global transparent colour after every palette
  load, and any art palette entry whose colour would collide with it
  is shifted by one blue LSB (imperceptible). Art should simply avoid
  drawing with index 254; Gfx2Next output does not need any special
  treatment otherwise.

## Building

The toolchain (not included in repo) lives in tools/ 
([sjasmplus](https://github.com/z00m128/sjasmplus), [DeZog](https://github.com/maziac/DeZog) VS Code plugin, [CSpect](https://github.com/z00m128/sjasmplus), DRC via [DAAD-READY](https://www.ngpaws.com/daadready/)).

- Build: powershell -File build.ps1 (add -Release for a release build,
  -Force1MB for the unexpanded-RAM test build)
- Run in CSpect: powershell -File build.ps1 -Run
- Clean: powershell -File build.ps1 -Clean
- Test DDB: powershell -File tests\build-tests.ps1 regenerates
  sd\GAME.DDB and the corrupt/oversize variants in tests\out\ (add
  -Suite to make the condact test suite DDB active - 63 checks
  covering condact semantics, parser/conjunction handling, DOALL
  nesting and save/load - or -Err4 for the nested-DOALL error demo)
- VS Code: build / run / clean tasks wrap the same script

## Layout

- src/ - Z80 source: main, hardware, interrupts, banks, file, tilemap,
  windows, ddbtext, print, input, engine, errors, objname, debug, and
  the overlay0/overlay1 condact handler pages
- sd/ - staged as the CSpect MMC filesystem
- tests/ - test adventure sources (template, condact suite, DOALL
  nesting demo), DDB build script and decoder
- tools/ - not included in repo but needed to build and run tests
    - tools/CSpect
    - tools/sjasmplus
    - tools/DAAD-READY
    - tools/Rabenstein-master (used for tests)

## Disclaimer

The development of NextDAAD is largely AI agent driven.