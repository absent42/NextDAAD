@echo off
REM Launcher only. The logic is lib\run.ps1.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "lib\run.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
