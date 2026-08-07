@echo off
setlocal EnableExtensions EnableDelayedExpansion
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

if not exist "IMAGES" (
    echo   no IMAGES\ - skipping graphics
    goto :title_readymade
)
if not exist "%GFX%" (
    echo ERROR: gfx2next not found at %GFX% - install Gfx2Next or fix TOOLSDIR in CONFIG.BAT
    exit /b 1
)
set "COUNT=0"
for %%F in ("IMAGES\*.png") do (
    if /I not "%%~nxF"=="DAAD.png" (
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
        REM Advisory palette audit - never fails the build. Skipped for
        REM ZX0 output, whose palette is compressed and not readable here.
        if not defined ZSUF powershell -NoProfile -ExecutionPolicy Bypass -File "lib\palcheck.ps1" "RELEASE\!NUM!.!MODE!"
        set /a COUNT+=1
        echo   image %%~nxF -^> !NUM!.!MODE!!ZSUF!
    )
)
echo   %COUNT% image^(s^) converted

REM ---- title screen (SP11): IMAGES\DAAD.png converts through the same
REM      gfx2next call as numbered art, but is never numbered - it is
REM      root-only (see SETUP.md "Title screens") so the output keeps the
REM      DAAD basename instead of a picture number.
if exist "IMAGES\DAAD.png" (
    set "TWIDTH="
    set "TMODE="
    for /f %%W in ('powershell -NoProfile -Command "$b=[System.IO.File]::ReadAllBytes('IMAGES\DAAD.png'); ([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19]"') do set "TWIDTH=%%W"
    if "!TWIDTH!"=="320" set "TMODE=NX2"
    if "!TWIDTH!"=="256" set "TMODE=NXI"
    if not defined TMODE (
        echo ERROR: DAAD.png - width !TWIDTH! ^(expected a 320 or 256 wide PNG^)
        exit /b 1
    )
    del "DAAD.nxi" "DAAD.nxi.zx0" 2>nul
    "%GFX%" -bitmap -pal-embed !ZX0! "IMAGES\DAAD.png" >nul 2>&1
    if errorlevel 1 (
        echo ERROR: gfx2next failed on DAAD.png - must be a paletted 8-bit PNG ^(max 256 colours^)
        del "DAAD.nxi" "DAAD.nxi.zx0" 2>nul
        exit /b 1
    )
    if not exist "DAAD.nxi!ZSUF!" (
        echo ERROR: gfx2next produced no output for DAAD.png
        exit /b 1
    )
    move /Y "DAAD.nxi!ZSUF!" "RELEASE\DAAD.!TMODE!!ZSUF!" >nul
    echo   title DAAD.png -^> DAAD.!TMODE!!ZSUF!
    set "TITLECONVERTED=1"
)

:title_readymade
REM ---- ready-made title: no IMAGES\DAAD.png (or no IMAGES\ at all) - a
REM      pre-converted DAAD.NX2/DAAD.NXI, or a ZX0 variant/8.3 synonym, in
REM      the kit folder root is staged to RELEASE\ as-is (authors with
REM      already-converted art). The IMAGES\DAAD.png conversion above wins
REM      if both exist. Probe order matches the interpreter's own title
REM      probe (compressed variants first).
if not defined TITLECONVERTED (
    set "TFOUND="
    for %%T in (DAAD.NX2.ZX0 DAAD.N2Z DAAD.NX2 DAAD.NXI.ZX0 DAAD.NXZ DAAD.NXI) do (
        if not defined TFOUND if exist "%%T" set "TFOUND=%%T"
    )
    if defined TFOUND (
        copy /Y "!TFOUND!" "RELEASE\!TFOUND!" >nul
        echo   title !TFOUND! -^> RELEASE\!TFOUND! ^(ready-made, staged as-is^)
    )
)
endlocal
exit /b 0
