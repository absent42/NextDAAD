@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
call "%~dp0CONFIG.BAT"

REM ---- resolve GAME (auto-detect single .DSF when blank) ----
if "%GAME%"=="" (
    set "_n=0"
    for %%F in (*.DSF) do (
        set /a _n+=1
        set "GAME=%%~nF"
    )
    if not "!_n!"=="1" (
        echo ERROR: set GAME in CONFIG.BAT ^(found !_n! .DSF files here, need exactly one^)
        pause
        exit /b 1
    )
)
if not exist "%GAME%.DSF" (
    echo ERROR: %GAME%.DSF not found in this folder
    pause
    exit /b 1
)

REM ---- derive tool paths ----
set "DR=%TOOLSDIR%\DAAD-READY"
set "DRF=%DR%\TOOLS\DRC\DRF.exe"
set "PHP=%DR%\PHP\php.exe"
set "DRB=%DR%\TOOLS\DRC\DRB.PHP"
set "GFX=%TOOLSDIR%\gfx2next\gfx2next.exe"
set "S2A=%TOOLSDIR%\ArkosTracker3\tools\SongToAky.exe"
set "S2E=%TOOLSDIR%\ArkosTracker3\tools\SongToSoundEffects.exe"

REM ---- preflight: always-required tools ----
for %%T in ("%DRF%" "%PHP%" "%DRB%" "%NEXFILE%") do (
    if not exist "%%~T" (
        echo ERROR: required tool missing: %%~T
        pause
        exit /b 1
    )
)

REM ---- refuse if CSpect holds RELEASE files open ----
tasklist /FI "IMAGENAME eq CSpect.exe" 2>nul | find /I "CSpect.exe" >nul && (
    echo ERROR: CSpect is running - close it before building
    pause
    exit /b 1
)

REM ---- prepare RELEASE\ and remove stale converted assets ----
if not exist "RELEASE" md "RELEASE"
del /Q "RELEASE\*.NX2" "RELEASE\*.NXI" "RELEASE\*.ZX0" "RELEASE\*.zx0" "RELEASE\*.AKY" "RELEASE\GAME.SFB" "RELEASE\GAME.DDB" 2>nul

echo Building %GAME% ...

call "%~dp0lib\ddb.bat"
if errorlevel 1 ( pause & exit /b 1 )

call "%~dp0lib\gfx.bat"
if errorlevel 1 ( pause & exit /b 1 )

call "%~dp0lib\audio.bat"
if errorlevel 1 ( pause & exit /b 1 )

REM === STAGE CALLS INSERTED HERE BY TASKS 9 ===

echo preflight OK
endlocal
exit /b 0
