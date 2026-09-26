@echo off
setlocal EnableExtensions
REM Pictures, title screen, pointers and sprite sets: IMAGES\ and the
REM kit-root DAAD.* title into RELEASE\. lib\assets.ps1 converts or copies
REM only what changed and removes outputs whose source is gone.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0assets.ps1" -Stage Pictures -Gfx "%GFX%" -Compress "%COMPRESS%"
if errorlevel 1 exit /b 1
endlocal
exit /b 0
