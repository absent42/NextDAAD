@echo off
setlocal EnableExtensions
cd /d "%~dp0"
call "%~dp0CONFIG.BAT"
if exist "%~dp0CONFIG.local.BAT" call "%~dp0CONFIG.local.BAT"
if exist "RELEASE" (
    del /Q "RELEASE\*" 2>nul
    echo cleaned RELEASE\
) else (
    echo nothing to clean
)
endlocal
