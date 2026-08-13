@echo off
setlocal EnableExtensions
cd /d "%~dp0"
call "%~dp0CONFIG.BAT"
if exist "%~dp0CONFIG.local.BAT" call "%~dp0CONFIG.local.BAT"
if not exist "RELEASE\nextdaad.nex" (
    echo ERROR: nothing built yet - run BUILD.BAT first
    pause
    exit /b 1
)
call "%~dp0lib\tools.bat"
if not exist "%CSPECT%" (
    echo ERROR: CSpect not found at %CSPECT%
    echo        Install CSpect there, or set CSPECTDIR in CONFIG.BAT to an
    echo        existing install.
    pause
    exit /b 1
)
"%CSPECT%" -w3 -zxnext -esc -mmc=RELEASE\ "RELEASE\nextdaad.nex"
endlocal
