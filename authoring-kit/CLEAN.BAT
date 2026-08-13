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
REM stray DDB build intermediates staged into the DAAD-READY folder
call "%~dp0lib\tools.bat"
del "%DAADDIR%\__ndb.*" 2>nul
endlocal
