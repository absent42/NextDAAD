@echo off
setlocal EnableExtensions
REM Module paths resolve against the caller's directory; the trailing \.
REM keeps a drive root's backslash from escaping the closing quote.
set "CALLERDIR=%CD%\."
cd /d "%~dp0"
call "%~dp0CONFIG.BAT"
if exist "%~dp0CONFIG.local.BAT" call "%~dp0CONFIG.local.BAT"
call "%~dp0lib\tools.bat"
REM Resolve SJASMPLUS to a full path now, while the working directory is
REM still the kit root (cd /d above). TOOLSDIR defaults to a RELATIVE
REM path, so SJASMPLUS is relative too; passed relative into PowerShell
REM it breaks once xbnbuild.ps1 changes directory.
for %%I in ("%SJASMPLUS%") do set "SJASMPLUS=%%~fI"
REM With no modules named, xbnbuild.ps1 prints the usage and module list.
REM Pass -SjasmPlus ONLY when the resolved path exists. SJASMPLUS always
REM holds a path (it defaults under TOOLSDIR), so passing it unconditionally
REM would satisfy xbnbuild's parameter check and skip its PATH fallback -
REM an author who has sjasmplus on PATH but has not downloaded it into the
REM kit would then fail every time. A deliberately-set-but-wrong
REM SJASMPLUSDIR falling through to PATH is the lesser evil.
if exist "%SJASMPLUS%" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\xbnbuild.ps1" %* -Out "%~dp0GAME.XBN" -BaseDir "%CALLERDIR%" -SjasmPlus "%SJASMPLUS%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\xbnbuild.ps1" %* -Out "%~dp0GAME.XBN" -BaseDir "%CALLERDIR%"
)
endlocal & exit /b %ERRORLEVEL%
