# NextDAAD

A DAAD text adventure interpreter for the ZX Spectrum Next, written in
Z80 assembly using the Next extended instruction set.

Status: Foundation milestone - boots, detects memory, loads and
validates a DAAD DDB from SD. No interpreter logic yet.

## Building

Requires Windows. The toolchain lives in tools/ (sjasmplus, CSpect,
DRC via DAAD-READY).

- Build: powershell -File build.ps1 (add -Release for a release build,
  -Force1MB for the unexpanded-RAM test build)
- Run in CSpect: powershell -File build.ps1 -Run
- Test DDB: powershell -File tests\build-tests.ps1 regenerates
  sd\GAME.DDB and the corrupt/oversize variants in tests\out\
- VS Code: build / run / clean tasks wrap the same script

## Layout

- src/ - Z80 source (main, hardware, interrupts, banks, file, debug)
- sd/ - staged as the CSpect MMC filesystem
- tests/ - test adventure source and DDB build script
- docs/, tools/ - reference material and toolchain (not tracked)
