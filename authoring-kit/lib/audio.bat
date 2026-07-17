@echo off
setlocal EnableExtensions EnableDelayedExpansion
if not exist "AUDIO" (
    echo   no AUDIO\ - skipping audio
    exit /b 0
)

REM ---- background music: <GAME>.aks -> GAME.AKY ----
if exist "AUDIO\%GAME%.aks" (
    "%S2A%" -bin --encodingAddress 0xD800 "AUDIO\%GAME%.aks" "RELEASE\GAME.AKY"
    if errorlevel 1 (
        echo ERROR: SongToAky failed on %GAME%.aks - the tune may be too large for the song slot ^(max 10208 bytes encoded at 0xD800^)
        exit /b 1
    )
    for %%A in ("RELEASE\GAME.AKY") do if %%~zA GTR 10208 (
        echo ERROR: GAME.AKY is %%~zA bytes, over the 10208 song limit
        exit /b 1
    )
    echo   music -^> GAME.AKY
)

REM ---- songs: numeric-named NNN.aks -> NNN.AKY ----
for %%F in ("AUDIO\*.aks") do (
    echo %%~nF| findstr /R "^[0-9][0-9]*$" >nul && (
        for /f %%N in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "'{0:D3}' -f [int]'%%~nF'"') do set "NUM=%%N"
        "%S2A%" -bin --encodingAddress 0xD800 "%%~fF" "RELEASE\!NUM!.AKY"
        if errorlevel 1 (
            echo ERROR: SongToAky failed on %%~nxF - the tune may be too large for the song slot ^(max 10208 bytes encoded at 0xD800^)
            exit /b 1
        )
        for %%A in ("RELEASE\!NUM!.AKY") do if %%~zA GTR 10208 (
            echo ERROR: !NUM!.AKY is %%~zA bytes, over the 10208 song limit
            exit /b 1
        )
        echo   song !NUM! -^> !NUM!.AKY
    )
)

REM ---- effects bank: <GAME>_FX.aks -> GAME.SFB (NON-FATAL) ----
if exist "AUDIO\%GAME%_FX.aks" (
    "%S2E%" -bin --encodingAddress 0xD000 "AUDIO\%GAME%_FX.aks" "RELEASE\GAME.SFB"
    if errorlevel 1 (
        echo   WARNING: effects bank skipped - SongToSoundEffects failed ^(recipe not yet pinned^)
        del "RELEASE\GAME.SFB" 2>nul
    ) else (
        for %%A in ("RELEASE\GAME.SFB") do if %%~zA GTR 2048 (
            echo   WARNING: GAME.SFB is %%~zA bytes, over the 2048 limit - dropped
            del "RELEASE\GAME.SFB" 2>nul
        )
        if exist "RELEASE\GAME.SFB" echo   effects -^> GAME.SFB
    )
)
endlocal
exit /b 0
