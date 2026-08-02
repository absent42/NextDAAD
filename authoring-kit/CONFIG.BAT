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
REM the same data rate - see VIDEO-PRESETS.md for which shape a clip wants.
SET VIDASPECT=

REM Frames per second for encoded cutscenes. Blank = 25. Audio floors: stereo
REM needs 10.17 or more, mono 7.60 or more, so 12.5 is available with sound
REM on both (see VIDEO-PRESETS.md).
SET VIDFPS=

REM Extra videnc options applied to every encode (e.g. --mono, or
REM --dither 0.3 to soften the blue-noise dither below its 0.5 default,
REM or --dither-mode mixture for the opt-in Yliluoma mixture dither).
REM --tile-slack (opt-in, default off) belongs in VIDOPTS_NNN rather
REM than here: on a title with sustained motion --tile-slack 0.5 lets
REM the budget-bound schedule work a row/column at a time instead of
REM four, which measurably helps pans and zooms and does nothing for
REM quiet material. See lib\videnc-README.md "Tile slack".
REM --prefilter (opt-in, default off) is the one to try on a grainy or
REM noisy source: it denoises lightly before scaling, trading a little
REM texture for supply headroom.
REM Recommended settings per kind of clip: VIDEO-PRESETS.md.
REM Full list: lib\videnc-README.md, or run the encoder with --help.
SET VIDOPTS=

REM Per-video overrides: VIDOPTS_NNN (3-digit video number) appends options
REM for that video only, after VIDOPTS. For most repeated options videnc
REM takes the last occurrence, so VIDOPTS_NNN wins over VIDOPTS - except
REM --aspect, which videnc always takes over --shape regardless of order;
REM a VIDOPTS_NNN that sets its own --shape/--width/--aspect still wins
REM for shape, but via the encode pass suppressing VIDASPECT for that
REM video rather than argument order. See lib\video.ps1's header comment.
REM The encode pass echoes each applied VIDOPTS_NNN. The one line below is
REM the worked example: video 002 is letterboxed 16:9 instead of the full
REM shape. Delete it when you replace 002.mp4 with your own footage.
REM NO --stream-budget IS SHIPPED HERE, AND NONE SHOULD BE. The kit used to
REM carry per-clip --stream-budget values hand-tuned to the demo cartoons,
REM which then silently applied to whatever the author dropped in as 001/002
REM and starved it. The encoder now derives the budget itself for every clip
REM and prints what it chose - set one by hand only to override that. See
REM SETUP.md "Streaming, resident and direct delivery".
SET VIDOPTS_002=--shape 16:9

REM DEPRECATED (honored one release): the v1 profile name. n0-n4 map to the
REM nearest v2 shape when VIDASPECT is blank. Use VIDASPECT instead.
SET VIDPROFILE=
