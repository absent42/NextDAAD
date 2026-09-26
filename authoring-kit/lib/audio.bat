@echo off
setlocal EnableExtensions
REM Samples, songs, streamed songs and the effects bank: AUDIO\ into
REM RELEASE\. lib\assets.ps1 converts or copies only what changed and
REM removes outputs whose source is gone.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0assets.ps1" -Stage Audio -Game "%GAME%" -S2A "%S2A%" -S2Y "%S2Y%" -S2E "%S2E%"
if errorlevel 1 exit /b 1
endlocal
exit /b 0
