@echo off
REM vidtune - GUI tuner for VIDEO\NNN.mp4 encodes. Prefers the shipped
REM exe (no Python needed); falls back to Python 3 with PySide6 + numpy
REM + Pillow. Same probe pattern as lib\video.ps1's encoder resolution.
REM /src (or -src, case-insensitive, first argument) skips the exe branch
REM and goes straight to the Python fallback chain below - source-mode for
REM development, when the shipped exe deliberately lags the lib sources.
setlocal
cd /d "%~dp0"
call "%~dp0CONFIG.BAT"
if exist "%~dp0CONFIG.local.BAT" call "%~dp0CONFIG.local.BAT"
call "%~dp0lib\tools.bat"
set PYTHONPATH=%~dp0lib;%PYTHONPATH%
set SRC_MODE=
if /I "%~1"=="/src" set SRC_MODE=1
if /I "%~1"=="-src" set SRC_MODE=1
if defined SRC_MODE goto :skip_exe
REM vidtune SHIPS with the kit, so it is probed in both the configured
REM location and the kit's own tools\ - the same rule lib\video.ps1
REM states for videnc.exe: a TOOLSDIR pointed elsewhere must not hide the
REM copy that came with the kit.
REM The >1MB test rejects the tiny text POINTER file a clone made without
REM git-lfs leaves at this path, rather than "running" it.
for %%V in ("%VIDTUNE%" "%~dp0tools\vidtune\vidtune.exe") do (
    if exist "%%~V" (
        for %%A in ("%%~V") do if %%~zA GTR 1000000 (
            start "" "%%~V"
            exit /b 0
        )
    )
)
:skip_exe
py -3 -c "import PySide6, numpy, PIL" >nul 2>&1 && (
    start "" py -3 -m vidtune
    exit /b 0
)
python -c "import PySide6, numpy, PIL" >nul 2>&1 && (
    start "" python -m vidtune
    exit /b 0
)
echo ERROR: vidtune not found. Looked for:
echo          %VIDTUNE%
echo          %~dp0tools\vidtune\vidtune.exe
echo        See tools\README.txt, or set VIDTUNEDIR in CONFIG.BAT
echo        or Python 3 with: pip install PySide6 numpy Pillow
exit /b 1
