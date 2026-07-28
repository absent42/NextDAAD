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

REM NXV v2 video shape for VIDEO\NNN.mp4 encoding (lib\videnc). Blank = full
REM (320x256 full-screen). Set a preset - full, 16:9, scope, classic,
REM classic-wide - or an explicit WIDTHxHEIGHT (width 256 or 320, any height,
REM e.g. 320x150), or a bare display-aspect number (e.g. 2.35) for a derived
REM free height at 320 wide. Smaller shapes come out at higher quality for
REM the same data rate - see SETUP.md "Video cutscenes".
SET VIDASPECT=

REM Frames per second for encoded cutscenes. Blank = 25. Audio floors: stereo
REM needs 24.40 or more, mono 18.22 or more (see SETUP.md).
SET VIDFPS=

REM Extra videnc options applied to every encode (e.g. --mono, or
REM --dither 0.3 to soften the blue-noise dither below its 0.5 default).
REM Full list: lib\videnc-README.md, or run the encoder with --help.
SET VIDOPTS=

REM Per-video overrides: VIDOPTS_NNN (3-digit video number) appends options
REM for that video only, after VIDOPTS. For most repeated options videnc
REM takes the last occurrence, so VIDOPTS_NNN wins over VIDOPTS - except
REM --aspect, which videnc always takes over --shape regardless of order;
REM a VIDOPTS_NNN that sets its own --shape/--width/--aspect still wins
REM for shape, but via the encode pass suppressing VIDASPECT for that
REM video rather than argument order. See lib\video.ps1's header comment.
REM The values below are TUNED TO THE SHIPPED DEMO CLIPS (001.mp4/002.mp4)
REM - delete these two lines when you replace them with your own videos,
REM or they will silently apply to whatever you drop in as 001/002. The
REM starter's demo clips use this: 001 keeps the full shape streamable
REM with the --stream-budget value the encoder's supply gate suggested,
REM 002 picks the 16:9 preset. See SETUP.md "Streaming, resident and
REM direct delivery". The encode pass echoes each applied VIDOPTS_NNN.
SET VIDOPTS_001=--stream-budget 0.50
SET VIDOPTS_002=--shape 16:9 --stream-budget 0.52

REM DEPRECATED (honored one release): the v1 profile name. n0-n4 map to the
REM nearest v2 shape when VIDASPECT is blank. Use VIDASPECT instead.
SET VIDPROFILE=
