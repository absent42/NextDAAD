# NextDAAD

A DAAD text adventure interpreter for the ZX Spectrum Next, written in
Z80 assembly using the Next extended instruction set.

Project status on 15/07/2026: 
The engine boots, loads and validates a DAAD DDB from SD, and runs it - 
object model, process/DOALL dispatch, windows, printing, colour, save-slot style
condacts, carrying/wearing, movement, vocabulary-driven parser
implemented (TIME, INPUT, PARSE). 118 of the 128 condacts are
implemented; the rest (SAVE/LOAD, RAMSAVE/RAMLOAD, SFX, BEEP, PICTURE,
MOUSE, GFX, CALL) are stubbed pending implementation.

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
- Debug build with an on-screen diagnostic console (frame counter,
  stub markers, register dumps)

Not yet implemented: save/load, sampled and AY sound effects, AY music
playback, Layer 2 picture display, mouse input, and EXTERN
subroutines.

## Building

The toolchain (not included in repo) lives in tools/ 
(sjasmplus, CSpect, DRC via DAAD-READY).

- Build: powershell -File build.ps1 (add -Release for a release build,
  -Force1MB for the unexpanded-RAM test build)
- Run in CSpect: powershell -File build.ps1 -Run
- Clean: powershell -File build.ps1 -Clean
- Test DDB: powershell -File tests\build-tests.ps1 regenerates
  sd\GAME.DDB and the corrupt/oversize variants in tests\out\ (add
  -Suite to make the condact test suite DDB active - 60 checks
  covering condact semantics, parser/conjunction handling and DOALL
  nesting - or -Err4 for the nested-DOALL error demo)
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