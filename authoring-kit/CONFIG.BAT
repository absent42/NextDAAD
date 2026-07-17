@echo off
REM ---- NextDAAD authoring kit configuration ----
REM Base name of your .DSF (without extension). Leave blank to auto-detect
REM when exactly one .DSF is present in this folder.
SET GAME=

REM 1 = ZX0-compress location graphics (smaller, uses the interpreter depack
REM path); 0 = raw NX2/NXI. Default is raw.
SET COMPRESS=0

REM 1 = launch CSpect on the result after a successful build; 0 = build only.
SET RUN=1

REM Location of the toolchain (DRC, gfx2next, Arkos tools, CSpect). Install the
REM tools into this folder - see tools\README.txt.
SET TOOLSDIR=tools

REM The pre-built interpreter to ship in RELEASE\ as nextdaad.nex.
SET NEXFILE=nextdaad.nex
