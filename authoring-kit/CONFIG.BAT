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

REM Text columns your game is authored for: blank = 80 (the default), or 40
REM for the double-width 40-column mode. Sets the compiler's COLS symbol
REM (ndrc -cols). The interpreter still boots at 80: a 40-column game must
REM issue GFX 1 18 in its init process - see docs\graphics.html.
SET COLS=

REM Location of the toolchain (gfx2next, Arkos tools, CSpect). Install the
REM tools into this folder - see tools\README.txt.
SET TOOLSDIR=tools

REM ---------------------------------------------------------------------
REM WHERE EACH TOOL LIVES
REM
REM Leave these BLANK and each falls under TOOLSDIR above, which is the
REM simple layout: one folder, everything in it, nothing to configure.
REM
REM Set one to point somewhere else if you ALREADY have that tool
REM installed - Arkos Tracker, CSpect and ffmpeg are general-purpose and
REM are commonly already on the machine. That saves keeping a second copy
REM in sync. Absolute paths are fine:
REM
REM   SET CSPECTDIR=C:\Emulators\CSpect
REM   SET ARKOSDIR=C:\Program Files\Arkos Tracker 3
REM   SET FFMPEGDIR=C:\ffmpeg
REM
REM Point at the folder the tool was installed into. For Arkos Tracker
REM and ffmpeg, whose programs sit in a subfolder (tools\ and bin\), the
REM install root and that subfolder are both accepted.
REM
REM Leave them blank here even if you move TOOLSDIR: CONFIG.local.BAT is
REM read after this file, so a path set there wins.
REM ---------------------------------------------------------------------

REM Gfx2Next - PNG to Layer 2 picture conversion.
SET GFXDIR=

REM Arkos Tracker 3 - SongToAky, SongToSoundEffects, SongToYm.
SET ARKOSDIR=

REM CSpect - the emulator BUILD.BAT and RUN.BAT launch.
SET CSPECTDIR=

REM ffmpeg - reads your .mp4 cutscene sources.
SET FFMPEGDIR=

REM videnc and vidtune - shipped with the kit; you should not need these.
SET VIDENCDIR=
SET VIDTUNEDIR=

REM The lib\ndrc.exe version this kit was tested against - BUILD.BAT refuses
REM to build with any other.
SET NDRCVER=0.2.1

REM Blank means lib\ndrc.exe - set to use a different ndrc build, and update NDRCVER above to match.
REM SET NDRC=

REM The pre-built interpreter to ship in RELEASE\ as nextdaad.nex.
SET NEXFILE=nextdaad.nex

REM NXV v2 video shape for VIDEO\NNN.mp4 encoding (lib\videnc). Blank = full
REM (320x256 full-screen). Set a preset - full, 16:9, scope, classic,
REM classic-wide - or an explicit WIDTHxHEIGHT (width 256 or 320, any height,
REM e.g. 320x150), or a bare display-aspect number (e.g. 2.35) for a derived
REM free height at 320 wide. Smaller shapes come out at higher quality for
REM the same data rate - see docs\video.html for which shape a clip wants.
SET VIDASPECT=

REM Frames per second for encoded cutscenes. Blank = 25. Audio floor: 10.17
REM or more, so 12.5 is available with sound (see docs\video.html).
SET VIDFPS=

REM Extra videnc options applied to every encode (e.g.
REM --dither 0.3 to soften the blue-noise dither below its 0.5 default,
REM or --dither-mode mixture for the opt-in Yliluoma mixture dither).
REM --tile-slack (off by default) belongs in VIDOPTS_NNN rather than
REM here: --tile-slack 0.5 helps a clip with sustained motion - pans and
REM zooms - and does nothing for quiet material. See
REM docs\reference\video-format.html "Tile slack".
REM --prefilter (off by default) is the one to try on a grainy or noisy
REM source: it denoises lightly before scaling, trading a little texture
REM for picture quality elsewhere.
REM Recommended settings per kind of clip: docs\video.html "The presets".
REM Full list: docs\reference\video-format.html, or run the encoder with --help.
SET VIDOPTS=

REM Per-video overrides: VIDOPTS_NNN (3-digit video number) appends options
REM for that video only, after VIDOPTS, and wins over it - including for
REM the shape, whichever of --shape/--width/--aspect you set. The encode
REM pass echoes each VIDOPTS_NNN it applies.
REM The encoder derives each clip's data budget and prints what it chose;
REM set --stream-budget only to override that - see
REM docs\reference\video-delivery.html "Streaming, resident and direct delivery".
REM The two lines below are worked examples for the demo clips - delete
REM them when you replace 001.mp4 and 002.mp4 with your own footage.
REM VIDOPTS_002=--fps 12.5 --dither 0.0 --tile-slack 0.5 --direct
REM VIDOPTS_001=--shape 16:9 --dither 0.25
