@echo off
REM Launcher only. The logic is lib\vidtune.ps1. /src or -src = Python source mode.
setlocal
cd /d "%~dp0"
set "SRCARG="
if /I "%~1"=="/src" set "SRCARG=-Src"
if /I "%~1"=="-src" set "SRCARG=-Src"
powershell -NoProfile -ExecutionPolicy Bypass -File "lib\vidtune.ps1" %SRCARG%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
