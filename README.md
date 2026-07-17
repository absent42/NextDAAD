# NextDAAD - ZX Spectrum Next DAAD interpreter

DAAD text adventure interpreter for the ZX Spectrum Next, written in
Z80 assembly using the Next extended instruction set.

Project status on 16/07/2026: 
The engine boots, loads and validates a DAAD DDB from SD, and runs it - 
object model, process/DOALL dispatch, windows, printing, colour,
carrying/wearing, movement, vocabulary-driven parser (TIME, INPUT,
PARSE), file-backed save/load, and Layer 2 location graphics
(PICTURE/DISPLAY) are implemented. 123 of the 128 condacts are
implemented; the rest (SFX, BEEP, MOUSE, GFX, CALL) are stubbed
pending implementation.

## Features

- Layer 2 location graphics: 256x192 and 320x256 256-colour pictures
  from Gfx2Next files, per-picture palettes, bank-allocated picture cache, and double-buffered draw
- 80 column tilemap-based 80x32 text mode driver with per-character colour and a custom 80 column font
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

Not yet implemented: sampled and AY sound effects, AY music playback,
mouse input, and EXTERN subroutines.

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