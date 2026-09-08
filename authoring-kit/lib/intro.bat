@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM Loader intro: compile INTRO.TXT into RELEASE\INTRO\ and stage the
REM launcher as RELEASE\%GAME%.NEX. No INTRO.TXT means no intro.
if not exist "INTRO.TXT" exit /b 0
REM introc.ps1 runs gfx2next from inside RELEASE\INTRO\ (where it writes its
REM output), so GFX must be absolute - TOOLSDIR's default is relative to
REM this folder and would resolve wrong one level down.
for %%I in ("%GFX%") do set "GFX=%%~fI"
if not exist "%GFX%" (
    echo ERROR: gfx2next not found at %GFX% - install Gfx2Next, or set GFXDIR in CONFIG.BAT
    goto :fail
)
if not exist "%INTRONEX%" (
    echo ERROR: launcher %INTRONEX% not found - the kit is incomplete
    goto :fail
)
REM Preflight only the tool the script's MUSIC line needs.
set "MKIND="
for /f "tokens=2" %%K in ('findstr /I /R "^ *MUSIC " INTRO.TXT') do if not defined MKIND set "MKIND=%%K"
if /I "!MKIND!"=="AKY" if not exist "%S2A%" (
    echo ERROR: SongToAky not found at %S2A% - MUSIC AKY needs Arkos Tracker 3 ^(ARKOSDIR in CONFIG.BAT^)
    goto :fail
)
if /I "!MKIND!"=="STREAM" if not exist "%S2Y%" (
    echo ERROR: SongToYm not found at %S2Y% - MUSIC STREAM needs Arkos Tracker 3 ^(ARKOSDIR in CONFIG.BAT^)
    goto :fail
)
if /I "!MKIND!"=="PCM" if not exist "%FFMPEG%" (
    echo ERROR: ffmpeg not found at %FFMPEG% - MUSIC PCM needs ffmpeg ^(FFMPEGDIR in CONFIG.BAT^)
    goto :fail
)
if /I "!MKIND!"=="NDR" if not exist "%NDAWBIN%" (
    echo ERROR: NextDAW runtime player not found at %NDAWBIN% - MUSIC NDR needs your NextDAW install ^(NEXTDAWDIR in CONFIG.BAT^)
    goto :fail
)
echo Compiling intro ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0introc.ps1" -Script "INTRO.TXT" -Root "%CD%" -Out "RELEASE\INTRO" -Cols "%COLS%" -Gfx "%GFX%" -S2A "%S2A%" -S2Y "%S2Y%" -Ffmpeg "%FFMPEG%" -NdawBin "%NDAWBIN%" -Palcheck "%~dp0palcheck.ps1" -Aysconv "%~dp0aysconv.ps1" -Launcher "%INTRONEX%" -LauncherOut "RELEASE\%GAME%.NEX"
if errorlevel 1 (
    echo ERROR: intro compile failed - see the message above
    goto :fail
)
echo   intro -^> RELEASE\INTRO\ and RELEASE\%GAME%.NEX ^(launch this file^)
endlocal
exit /b 0
:fail
endlocal
exit /b 1
