@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM ---- video cutscenes (SP13): VIDEO\NNN.vid -> RELEASE\NNN.VID, straight
REM      copy, no conversion, no tool - the file must already be a valid
REM      MakeVid/playvid .VID (six auto-detected formats, classified by
REM      size). Played by GFX n 13 (once) / GFX n 14 (loop), aliased as
REM      the classic SFX n 9/10 (PLAYFLI/PLAYFLIL). See SETUP.md's "Video
REM      cutscenes" section for the formats, the encode workflow (MakeVid
REM      or lib\videnc.py) and playback caveats. Same numeric-name pattern
REM      as the WAV block in lib\audio.bat.
if not exist "VIDEO" (
    echo   no VIDEO\ - skipping video cutscenes
    exit /b 0
)
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
