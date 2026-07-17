@echo off
setlocal EnableExtensions
cd /d "%~dp0"
call "%~dp0CONFIG.BAT"
if exist "RELEASE" (
    del /Q "RELEASE\*" 2>nul
    echo cleaned RELEASE\
) else (
    echo nothing to clean
)
REM stray DDB build intermediates staged into the DAAD-READY folder
del "%TOOLSDIR%\DAAD-READY\__ndb.*" 2>nul
endlocal
