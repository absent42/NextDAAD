@echo off
setlocal EnableExtensions
cd /d "%~dp0"
call "%~dp0CONFIG.BAT"
if exist "%~dp0CONFIG.local.BAT" call "%~dp0CONFIG.local.BAT"
if exist "RELEASE" (
    del /Q "RELEASE\*" 2>nul
    if exist "RELEASE\INTRO" rd /S /Q "RELEASE\INTRO"
    for %%F in (RELEASE\*.NEX) do if /I not "%%~nxF"=="nextdaad.nex" del /Q "%%F"
    echo cleaned RELEASE\
) else (
    echo nothing to clean
)
endlocal
