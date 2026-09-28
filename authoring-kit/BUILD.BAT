@echo off
REM Launcher only. The build is lib\build.ps1; keep this file trivial.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "lib\build.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
