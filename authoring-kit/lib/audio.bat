@echo off
setlocal EnableExtensions EnableDelayedExpansion
if not exist "AUDIO" (
    echo   no AUDIO\ - skipping audio
    exit /b 0
)
REM ---- sampled sound: numeric-named NNN.wav -> NNN.WAV (straight copy, no
REM      conversion, no tool). Author supplies PCM mono 8-bit WAV; the game
REM      plays it with SFX n 1 (once) / SFX n 2 (looped). ----
for %%F in ("AUDIO\*.wav") do (
    echo %%~nF| findstr /R "^[0-9][0-9]*$" >nul && (
        for /f %%N in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "'{0:D3}' -f [int]'%%~nF'"') do set "NUM=%%N"
        copy /Y "%%~fF" "RELEASE\!NUM!.WAV" >nul
        if errorlevel 1 (
            echo ERROR: could not copy sample %%~nxF
            exit /b 1
        )
        echo   sample !NUM! -^> !NUM!.WAV
    )
)

REM ---- Arkos .aks conversions (music/songs/effects) need SongToAky. Skip the
REM      whole leg if there are no NON-STREAM .aks sources - a samples-only
REM      game does not need Arkos Tracker installed, and a streamed-only
REM      game (AUDIO\ holding only STREAM_NNN.aks) needs SongToYm, not
REM      SongToAky - checked separately below. STREAM_*.aks would already
REM      fail to match the background-music/numbered-song patterns further
REM      down, but the plain "AUDIO\*.aks" existence check does not know
REM      that, so it is scoped here to non-STREAM_ names explicitly. ----
set "HAS_AKY_SRC="
for %%F in ("AUDIO\*.aks") do (
    echo %%~nF| findstr /R /V "^STREAM_" >nul && set "HAS_AKY_SRC=1"
)
if not defined HAS_AKY_SRC goto :aky_done
if not exist "%S2A%" (
    echo ERROR: SongToAky not found at %S2A% - install Arkos Tracker 3 or fix TOOLSDIR in CONFIG.BAT
    exit /b 1
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
:aky_done

REM ---- streamed songs: STREAM_NNN.aks -> NNN.AYS (per-frame AY-register-
REM      diff stream for multi-PSG tunes too big for the AKY song slot -
REM      see lib\aysconv.ps1's header comment for the AYS format and the
REM      SongToYm recipe. Needs SongToYm; skip the whole leg if there are
REM      no STREAM_*.aks sources. ----
if not exist "AUDIO\STREAM_*.aks" goto :stream_done
if not exist "%S2Y%" (
    echo ERROR: SongToYm not found at %S2Y% - install Arkos Tracker 3 or fix TOOLSDIR in CONFIG.BAT
    exit /b 1
)
REM NOTE: %~dp0 here is THIS script's own folder (lib\), not the kit root -
REM aysconv.ps1 lives right beside audio.bat, so no "lib\" prefix.
if not exist "%~dp0aysconv.ps1" (
    echo ERROR: %~dp0aysconv.ps1 missing - kit installation is incomplete
    exit /b 1
)
REM NOTE: exit /b from inside this nested for/&&/if does NOT reliably
REM propagate errorlevel back out of a "call"ed batch file (verified
REM empirically) - set a flag instead and exit /b once, flat, after the
REM loop.
set "AYS_FAIL="
for %%F in ("AUDIO\STREAM_*.aks") do (
    echo %%~nF| findstr /R "^STREAM_[0-9][0-9]*$" >nul && (
        for /f %%N in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "'{0:D3}' -f [int]('%%~nF' -replace '^STREAM_','')"') do set "NUM=%%N"
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0aysconv.ps1" -Song "%%~fF" -Out "RELEASE\!NUM!.AYS" -SongToYm "%S2Y%"
        if errorlevel 1 (
            echo ERROR: aysconv.ps1 failed on %%~nxF
            set "AYS_FAIL=1"
        ) else (
            echo   stream !NUM! -^> !NUM!.AYS
        )
    )
)
if defined AYS_FAIL exit /b 1
:stream_done

REM ---- effects bank: <GAME>_FX.aks -> GAME.SFB (NON-FATAL) ----
if exist "AUDIO\%GAME%_FX.aks" (
    if not exist "%S2E%" (
        echo   WARNING: SongToSoundEffects not found - effects bank skipped
    ) else (
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
)
:aks_done
endlocal
exit /b 0
