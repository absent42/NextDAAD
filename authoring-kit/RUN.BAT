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
set "CSPECT=%TOOLSDIR%\CSpect\CSpect.exe"
if not exist "%CSPECT%" (
    echo ERROR: CSpect not found at %CSPECT%
    pause
    exit /b 1
)
"%CSPECT%" -w3 -zxnext -esc -mmc=RELEASE\ "RELEASE\nextdaad.nex"
endlocal
