@echo off
REM ---------------------------------------------------------------------
REM Resolve every third-party tool to a concrete path.
REM
REM Called by BUILD.BAT, RUN.BAT and VIDTUNE.BAT immediately
REM after CONFIG.BAT and CONFIG.local.BAT have BOTH been loaded - the
REM defaults below are derived from TOOLSDIR, so resolving any earlier
REM would freeze the pre-override value in (which is exactly the bug a
REM tool directory expanded in CONFIG.BAT once had: a CONFIG.local.BAT
REM that relocated TOOLSDIR moved every tool except that one).
REM
REM NO setlocal HERE, deliberately: this script exists to set variables in
REM its caller's scope. Adding one would discard everything it does.
REM
REM WHY PER-TOOL DIRECTORIES. TOOLSDIR assumes one folder holding every
REM tool, which forces a second copy of Arkos Tracker, CSpect or ffmpeg on
REM anyone who already has them installed. Each tool now takes its own
REM optional override; whatever is left blank still falls under TOOLSDIR,
REM so an author who wants the simple single-folder layout does nothing.
REM
REM Two shapes are probed for the tools whose executables sit one level
REM down (Arkos in tools\, ffmpeg in bin\), because pointing at an
REM existing install's ROOT and pointing at the folder that actually holds
REM the .exe are both reasonable readings of "where the tool is".
REM ---------------------------------------------------------------------

if not defined TOOLSDIR set "TOOLSDIR=tools"

REM ---- per-tool directories: blank means "under TOOLSDIR" ----
if not defined GFXDIR     set "GFXDIR=%TOOLSDIR%\gfx2next"
if not defined ARKOSDIR   set "ARKOSDIR=%TOOLSDIR%\ArkosTracker3"
if not defined CSPECTDIR  set "CSPECTDIR=%TOOLSDIR%\CSpect"
if not defined FFMPEGDIR  set "FFMPEGDIR=%TOOLSDIR%\ffmpeg"
if not defined SJASMPLUSDIR set "SJASMPLUSDIR=%TOOLSDIR%\sjasmplus"
if not defined VIDENCDIR  set "VIDENCDIR=%TOOLSDIR%\videnc"
if not defined VIDTUNEDIR set "VIDTUNEDIR=%TOOLSDIR%\vidtune"

REM ---- executables ----
REM ndrc is the DAAD compiler, shipped inside the kit's own lib\ rather
REM than installed under TOOLSDIR: nothing to fetch, and the version the
REM kit was tested against is the version that runs. Overridable from
REM CONFIG.local.BAT for compiler work - hence "if not defined".
if not defined NDRC set "NDRC=%~dp0ndrc.exe"
set "GFX=%GFXDIR%\gfx2next.exe"
set "CSPECT=%CSPECTDIR%\CSpect.exe"
set "VIDENC=%VIDENCDIR%\videnc.exe"
set "VIDTUNE=%VIDTUNEDIR%\vidtune.exe"

REM Arkos Tracker keeps its converters in a tools\ subfolder, so an
REM install root and the folder holding the .exe files are one level
REM apart. Accept either.
set "ARKOSBIN=%ARKOSDIR%"
if not exist "%ARKOSBIN%\SongToAky.exe" if exist "%ARKOSDIR%\tools\SongToAky.exe" set "ARKOSBIN=%ARKOSDIR%\tools"
set "S2A=%ARKOSBIN%\SongToAky.exe"
set "S2E=%ARKOSBIN%\SongToSoundEffects.exe"
set "S2Y=%ARKOSBIN%\SongToYm.exe"

REM ffmpeg release builds put the binaries in bin\. Same two shapes.
set "FFMPEGBIN=%FFMPEGDIR%"
if not exist "%FFMPEGBIN%\ffmpeg.exe" if exist "%FFMPEGDIR%\bin\ffmpeg.exe" set "FFMPEGBIN=%FFMPEGDIR%\bin"
set "FFMPEG=%FFMPEGBIN%\ffmpeg.exe"

REM sjasmplus zips extract either flat or into a versioned folder. Same two
REM shapes as Arkos and ffmpeg above, but the nested name is not fixed.
set "SJASMPLUSBIN=%SJASMPLUSDIR%"
if not exist "%SJASMPLUSBIN%\sjasmplus.exe" for /d %%D in ("%SJASMPLUSDIR%\*") do if exist "%%D\sjasmplus.exe" set "SJASMPLUSBIN=%%D"
set "SJASMPLUS=%SJASMPLUSBIN%\sjasmplus.exe"

REM lib\video.ps1 and the vidtune GUI read these from the environment.
REM Exported as resolved FILE paths so the PowerShell side never has to
REM repeat the probing above and drift from it.
set "FFMPEG=%FFMPEG%"
set "VIDENC=%VIDENC%"
exit /b 0
