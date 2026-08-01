@echo off
REM vidtune - GUI tuner for VIDEO\NNN.mp4 encodes. Prefers the shipped
REM exe (no Python needed); falls back to Python 3 with PySide6 + numpy
REM + Pillow. Same probe pattern as lib\video.ps1's encoder resolution.
setlocal
cd /d "%~dp0"
set PYTHONPATH=%~dp0lib;%PYTHONPATH%
if exist "tools\vidtune\vidtune.exe" (
    for %%A in ("tools\vidtune\vidtune.exe") do if %%~zA GTR 1000000 (
        start "" "tools\vidtune\vidtune.exe"
        exit /b 0
    )
)
py -3 -c "import PySide6, numpy, PIL" >nul 2>&1 && (
    start "" py -3 -m vidtune
    exit /b 0
)
python -c "import PySide6, numpy, PIL" >nul 2>&1 && (
    start "" python -m vidtune
    exit /b 0
)
echo ERROR: vidtune needs tools\vidtune\vidtune.exe (see tools\README.txt)
echo        or Python 3 with: pip install PySide6 numpy Pillow
exit /b 1
