@echo off
setlocal EnableExtensions EnableDelayedExpansion
if not exist "IMAGES" (
    echo   no IMAGES\ - skipping graphics
    exit /b 0
)
REM gfx2next behavior (verified against the vendored v1.1.24):
REM  - it requires a paletted 8-bit PNG (<=256 colours); truecolour is rejected.
REM  - it takes ONLY an input path and writes <inputbase>.nxi to the CURRENT
REM    directory (it does not accept an output path). With -zx0 it writes
REM    <inputbase>.nxi.zx0 instead (no plain .nxi is left).
REM So: run gfx2next, then MOVE the produced file to RELEASE with the mode-
REM correct name (.NX2 for 320-wide, .NXI for 256-wide, +.zx0 when compressed).
set "ZX0="
set "ZSUF="
if "%COMPRESS%"=="1" ( set "ZX0=-zx0" & set "ZSUF=.zx0" )
set "COUNT=0"
for %%F in ("IMAGES\*.png") do (
    set "NUM="
    set "MODE="
    for /f "tokens=1,2" %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -File "lib\pnginfo.ps1" "%%~fF"') do (
        set "NUM=%%A"
        set "MODE=%%B"
    )
    if not defined MODE (
        echo ERROR: %%~nxF - !NUM! ^(expected a 320 or 256 wide PNG named with a picture number^)
        exit /b 1
    )
    REM gfx2next writes to CWD by input basename; clear any stale output first.
    del "%%~nF.nxi" "%%~nF.nxi.zx0" 2>nul
    "%GFX%" -bitmap -pal-embed !ZX0! "IMAGES\%%~nxF" >nul 2>&1
    if errorlevel 1 (
        echo ERROR: gfx2next failed on %%~nxF - must be a paletted 8-bit PNG ^(max 256 colours^)
        del "%%~nF.nxi" "%%~nF.nxi.zx0" 2>nul
        exit /b 1
    )
    if not exist "%%~nF.nxi!ZSUF!" (
        echo ERROR: gfx2next produced no output for %%~nxF
        exit /b 1
    )
    move /Y "%%~nF.nxi!ZSUF!" "RELEASE\!NUM!.!MODE!!ZSUF!" >nul
    set /a COUNT+=1
    echo   image %%~nxF -^> !NUM!.!MODE!!ZSUF!
)
echo   %COUNT% image^(s^) converted
endlocal
exit /b 0
