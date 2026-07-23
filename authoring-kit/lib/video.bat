@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM ---- video cutscenes (SP14a NXV): two source kinds in VIDEO\ ----
REM   VIDEO\NNN.mp4 - encoded to VIDEO\NNN.vid by lib\video.ps1 (which
REM      runs lib\videnc.py) whenever the .vid is missing or older than
REM      the .mp4; the .vid beside the source is the encode cache, so a
REM      slow encode runs once per source change, not once per build.
REM      Needs Python 3 + Pillow and ffmpeg - see tools\README.txt.
REM      Profile: VIDPROFILE in CONFIG.BAT (blank = auto).
REM   VIDEO\NNN.vid - pre-encoded native NXV file, staged as-is.
REM Both end up as RELEASE\NNN.VID, played by GFX n 13 (once) / GFX n 14
REM (loop), aliased as the classic SFX n 9/10 (PLAYFLI/PLAYFLIL). See
REM SETUP.md's "Video cutscenes" section. MakeVid .VID files are NOT
REM playable any more (the interpreter plays only native NXV) - re-encode
REM from the original video source. Same numeric-name pattern as the WAV
REM block in lib\audio.bat.
if not exist "VIDEO" (
    echo   no VIDEO\ - skipping video cutscenes
    exit /b 0
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0video.ps1"
if errorlevel 1 exit /b 1
for %%F in ("VIDEO\*.vid") do (
    echo %%~nF| findstr /R "^[0-9][0-9]*$" >nul && (
        for /f %%N in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "'{0:D3}' -f [int]'%%~nF'"') do set "NUM=%%N"
        copy /Y "%%~fF" "RELEASE\!NUM!.VID" >nul
        if errorlevel 1 (
            echo ERROR: could not copy video %%~nxF
            exit /b 1
        )
        echo   video !NUM! -^> !NUM!.VID
    )
)
endlocal
exit /b 0
