@echo off
setlocal EnableExtensions EnableDelayedExpansion
if not exist "IMAGES" (
    echo   no IMAGES\ - skipping graphics
    exit /b 0
)
set "ZX0="
if "%COMPRESS%"=="1" set "ZX0=-zx0"
set "COUNT=0"
for %%F in ("IMAGES\*.png") do (
    set "INFO="
    for /f "tokens=1,2" %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -File "lib\pnginfo.ps1" "%%~fF"') do (
        set "NUM=%%A"
        set "MODE=%%B"
        set "INFO=1"
    )
    if not defined MODE (
        echo ERROR: %%~nxF - !NUM! ^(expected a 320 or 256 wide PNG named with a picture number^)
        exit /b 1
    )
    "%GFX%" -bitmap -pal-embed !ZX0! "%%~fF" "RELEASE\!NUM!.!MODE!"
    if errorlevel 1 (
        echo ERROR: gfx2next failed converting %%~nxF
        exit /b 1
    )
    set /a COUNT+=1
    echo   image %%~nxF -^> !NUM!.!MODE!!ZX0:~0,0!
)
echo   %COUNT% image^(s^) converted
endlocal
exit /b 0
