@echo off
REM Launcher only. The logic is lib\clean.ps1.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "lib\clean.ps1"
exit /b %ERRORLEVEL%
