@echo off
setlocal EnableExtensions
REM ---- video cutscenes (NXV v2): two source kinds in VIDEO\ ----
REM   VIDEO\NNN.mp4 - encoded to VIDEO\NNN.vid by lib\video.ps1 whenever the
REM      .vid is missing, older than the .mp4, or its VIDEO\NNN.vid.args
REM      option hash differs. Needs ffmpeg - see tools\README.txt.
REM      Shape/options: VIDASPECT, VIDFPS, VIDOPTS, VIDOPTS_NNN in CONFIG.BAT.
REM   VIDEO\NNN.vid - pre-encoded native NXV file, staged as-is.
REM Both end up as RELEASE\NNN.VID, played by GFX n 13 (once) / GFX n 14
REM (loop). lib\assets.ps1 copies only changed clips and removes a .VID
REM whose source is gone, so it runs even with no VIDEO\.
if not exist "VIDEO" goto :stage
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0video.ps1"
if errorlevel 1 exit /b 1
:stage
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0assets.ps1" -Stage Video
if errorlevel 1 exit /b 1
endlocal
exit /b 0
