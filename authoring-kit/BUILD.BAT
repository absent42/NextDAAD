@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
call "%~dp0CONFIG.BAT"
if exist "%~dp0CONFIG.local.BAT" call "%~dp0CONFIG.local.BAT"

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
set "DRB=%DRCDIR%\src\drb.php"
if not exist "%DRB%" set "DRB=%DRCDIR%\TOOLS\DRC\DRB.PHP"
set "DRTARGET=nextdaad"
if not exist "%DRB%" (
    echo ERROR: no DRB.PHP at %DRB%
    echo Install the NextDAAD DRC fork into %DRCDIR% - see tools\README.txt.
    pause
    exit /b 1
)
findstr /C:"NEXTDAAD" "%DRB%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: the DRC at %DRCDIR% has no NEXTDAAD target.
    echo NextDAAD databases cannot be built with it. Update the fork,
    echo or point DRCDIR in CONFIG.BAT at one that has the target.
    pause
    exit /b 1
)
set "GFX=%TOOLSDIR%\gfx2next\gfx2next.exe"
set "S2A=%TOOLSDIR%\ArkosTracker3\tools\SongToAky.exe"
set "S2E=%TOOLSDIR%\ArkosTracker3\tools\SongToSoundEffects.exe"
set "S2Y=%TOOLSDIR%\ArkosTracker3\tools\SongToYm.exe"

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
REM      *.N2Z/*.NXZ are the 8.3 title synonyms (see lib\gfx.bat's
REM      ready-made DAAD.* staging) - covered here so a title removed
REM      since the last build cannot leave a stray DAAD.N2Z/DAAD.NXZ
REM      behind on the SD card. RELEASE\FONT.CHR is covered too (SP12
REM      T2 - see the ready-made font staging below) so a font removed
REM      from the kit root cannot leave a stray RELEASE\FONT.CHR behind.
REM      RELEASE\POINTER.SPR is covered the same way (SP12 T3 - see the
REM      ready-made pointer staging below). RELEASE\FONT1-9.CHR and
REM      RELEASE\POINTER1-9.SPR need the same treatment (SP18): a stale
REM      numbered asset that still loads is worse than a missing one -
REM      a font or pointer removed from the kit root must not leave a
REM      RELEASE\ copy behind for GFX n 16 / MOUSE n 5 to keep silently
REM      installing. Cleaned in the numbered loop just below, same
REM      idiom as the multi-part GAME<n>.DDB cleanup that follows it.
if not exist "RELEASE" md "RELEASE"
del /Q "RELEASE\*.NX2" "RELEASE\*.NXI" "RELEASE\*.ZX0" "RELEASE\*.zx0" "RELEASE\*.N2Z" "RELEASE\*.NXZ" "RELEASE\*.AKY" "RELEASE\*.AYS" "RELEASE\*.VID" "RELEASE\*.WAV" "RELEASE\GAME.SFB" "RELEASE\GAME.DDB" "RELEASE\FONT.CHR" "RELEASE\POINTER.SPR" 2>nul
for %%N in (1 2 3 4 5 6 7 8 9) do (
    del /Q "RELEASE\FONT%%N.CHR" "RELEASE\POINTER%%N.SPR" 2>nul
)
REM ---- remove stale multi-part output too, so a part removed since the
REM      last build (its PART<n> folder deleted) cannot leave a stray
REM      GAME<n>.DDB or PART<n>\ behind on the SD card - see
REM      docs\multi-part-games.html, "Switching parts" (no stray files
REM      beside a part's GAME<n>.DDB).
for %%N in (2 3 4 5 6 7 8 9) do (
    del /Q "RELEASE\GAME%%N.DDB" 2>nul
    if exist "RELEASE\PART%%N" rd /S /Q "RELEASE\PART%%N"
)

echo Building %GAME% ...

call "%~dp0lib\ddb.bat"
if errorlevel 1 ( pause & exit /b 1 )

call "%~dp0lib\gfx.bat"
if errorlevel 1 ( pause & exit /b 1 )

call "%~dp0lib\audio.bat"
if errorlevel 1 ( pause & exit /b 1 )

call "%~dp0lib\video.bat"
if errorlevel 1 ( pause & exit /b 1 )

call "%~dp0lib\assemble.bat"
if errorlevel 1 ( pause & exit /b 1 )

REM ---- classic charsets (SP18): a kit-root FONT.ch8 / FONT<n>.ch8 is a
REM      768-byte classic ZX charset (chars 32-127). Convert it here so
REM      the author does not have to remember the command, the same way
REM      IMAGES\*.png is converted rather than staged. A ready-made
REM      FONT<n>.CHR staged below overwrites the converted result, so a
REM      hand-built full table always wins. RELEASE\FONT<n>.CHR was
REM      already wiped by the stale-clean near the top of this script, so
REM      a .ch8 removed since the last build cannot leave a stray
REM      converted .CHR behind either - this loop only ever recreates
REM      what it finds a source for.
REM      NOTE: the "else" here is load-bearing. Verified empirically:
REM      inside a for loop, an "exit /b 1" in a nested block returns 0 to
REM      the caller whenever any command follows that block's closing ")"
REM      within the same enclosing parens. cmd.exe still stops (no further
REM      iterations, no further script) but the PROCESS exit code silently
REM      resets to 0, so a caller checking errorlevel never sees the
REM      failure. The trigger is the trailing command, NOT the "||" form -
REM      plain "if errorlevel 1 ( ... exit /b 1 )" is affected exactly the
REM      same way. Two shapes are safe: "if errorlevel 1 (...) else (...)",
REM      which leaves nothing after the block, as used here; or ending the
REM      block with "goto :label" and putting "exit /b 1" at top level, as
REM      the multi-part loop below does for its seven failure sites. Same
REM      class of hazard lib\audio.bat's STREAM_*.aks loop comment already
REM      documents, different trigger.
for %%F in ("FONT.ch8" "FONT1.ch8" "FONT2.ch8" "FONT3.ch8" "FONT4.ch8" ^
            "FONT5.ch8" "FONT6.ch8" "FONT7.ch8" "FONT8.ch8" "FONT9.ch8") do (
    if exist %%F (
        powershell -NoProfile -ExecutionPolicy Bypass -File "lib\fontconv.ps1" -In %%F -Out "RELEASE\%%~nF.CHR"
        if errorlevel 1 (
            echo ERROR: fontconv failed converting %%F
            pause
            exit /b 1
        ) else (
            echo   font %%~nxF -^> RELEASE\%%~nF.CHR ^(converted, 768 -^> 2048^)
        )
    )
)

REM ---- ready-made font (SP12 T2): a kit-root FONT.CHR - already a full
REM      2048-byte glyph table, see lib\fontconv.ps1 for how to make one
REM      from a classic 768-byte ZX charset - is staged to RELEASE\ as-is,
REM      no conversion. Mirrors lib\gfx.bat's ready-made DAAD.* title
REM      staging (9fe5557). No FONT.CHR in the kit root is normal (the
REM      embedded font plays) and not an error. PART<n>\FONT.CHR needs no
REM      staging step here - it already rides the generic PART<n>\ asset
REM      copy loop below (SP11 T6), same as any other per-part asset.
if exist "FONT.CHR" (
    copy /Y "FONT.CHR" "RELEASE\FONT.CHR" >nul
    echo   font FONT.CHR -^> RELEASE\FONT.CHR ^(ready-made, staged as-is^)
)

REM ---- numbered ready-made fonts (SP18): FONT1.CHR..FONT9.CHR are the
REM      runtime-selectable fonts GFX n 16 installs. Same as FONT.CHR
REM      above - already full 2048-byte tables, staged as-is. Absent is
REM      normal (a game that never switches fonts ships none).
for %%N in (1 2 3 4 5 6 7 8 9) do (
    if exist "FONT%%N.CHR" (
        copy /Y "FONT%%N.CHR" "RELEASE\FONT%%N.CHR" >nul
        echo   font FONT%%N.CHR -^> RELEASE\FONT%%N.CHR ^(ready-made, staged as-is^)
    )
)

REM ---- ready-made mouse pointer (SP12 T3): a kit-root POINTER.SPR - a
REM      raw 256-byte 16x16 8-bit hardware sprite pattern, see
REM      docs\customising.html "Custom mouse pointer" for the format and
REM      a sprite-editor workflow - is staged to RELEASE\ as-is, no
REM      conversion run here. IMAGES\POINTER.png is the source-art
REM      alternative (SP18): lib\gfx.bat converts it via gfx2next -sprites
REM      -pal-std before this stage runs, so a kit-root POINTER.SPR staged
REM      here overwrites that conversion when both are present - keep
REM      only one.
REM      Mirrors the ready-made FONT.CHR staging just above and
REM      lib\gfx.bat's ready-made DAAD.* title staging (9fe5557). No
REM      POINTER.SPR in the kit root is normal (the default arrow plays)
REM      and not an error. PART<n>\POINTER.SPR needs no staging step here
REM      - it already rides the generic PART<n>\ asset copy loop below
REM      (SP11 T6), same as any other per-part asset.
if exist "POINTER.SPR" (
    copy /Y "POINTER.SPR" "RELEASE\POINTER.SPR" >nul
    echo   pointer POINTER.SPR -^> RELEASE\POINTER.SPR ^(ready-made, staged as-is^)
)

REM ---- numbered ready-made pointers (SP18): POINTER1.SPR..POINTER9.SPR
REM      are the runtime-selectable pointers MOUSE n 5 installs. Same as
REM      POINTER.SPR above - already full 256-byte sprite patterns,
REM      staged as-is (and likewise overwriting IMAGES\POINTERn.png's
REM      conversion in lib\gfx.bat when both are present). Absent is
REM      normal (a game that never switches pointers ships none).
for %%N in (1 2 3 4 5 6 7 8 9) do (
    if exist "POINTER%%N.SPR" (
        copy /Y "POINTER%%N.SPR" "RELEASE\POINTER%%N.SPR" >nul
        echo   pointer POINTER%%N.SPR -^> RELEASE\POINTER%%N.SPR ^(ready-made, staged as-is^)
    )
)

REM ---- multi-part games (SP11 Task 6): PART2\..PART9\ source folders,
REM      matching the interpreter's own supported part range (h_xpart
REM      validates 1-9; part 1 is the main game already built above).
REM      Each PART<n>\ holds exactly one .DSF (auto-detected the same
REM      way as GAME above) plus any ALREADY-CONVERTED art/audio for
REM      that part - this loop stages those files as-is, it does not
REM      run gfx.bat/audio.bat again. A missing PART<n>\ is normal (a
REM      single-part game) and is skipped silently, not an error.
REM      lib\ddb.bat cannot be reused unchanged here - it always writes
REM      the fixed names RELEASE\GAME.DDB / RELEASE\0.XMB, so this loop
REM      mirrors its DRF/DRB/pre-clean/size-check shape inline (SP10's
REM      XMB staging commit 4a68620 is the shape it follows) and writes
REM      RELEASE\GAME<n>.DDB / RELEASE\PART<n>\0.XMB instead.
for %%I in ("%DR%") do set "DR=%%~fI"
for %%I in ("%DRF%") do set "DRF=%%~fI"
for %%I in ("%PHP%") do set "PHP=%%~fI"
for %%I in ("%DRB%") do set "DRB=%%~fI"
for %%N in (2 3 4 5 6 7 8 9) do (
    if exist "PART%%N\*.DSF" (
        set "PGAME="
        set "_pn=0"
        for %%F in ("PART%%N\*.DSF") do (
            set /a _pn+=1
            set "PGAME=%%~nF"
        )
        if not "!_pn!"=="1" (
            echo ERROR: PART%%N\ has !_pn! .DSF files - keep exactly one game source per part folder
            pause
            goto :part_fail
        )
        echo Building part %%N ^(!PGAME!^) ...
        copy /Y "PART%%N\!PGAME!.DSF" "%DR%\__ndbpart.DSF" >nul || (
            echo ERROR: could not stage PART%%N\!PGAME!.DSF into %DR%
            pause
            goto :part_fail
        )
        pushd "%DR%"
        REM -v3 as in lib\ddb.bat - every part must compile to the same
        REM dialect as part 1, since a part switch reloads a header and
        REM the flags carry across. See docs\daad-v3.html "Moving an
        REM existing version 2 game to V3" for the three migration hazards.
        "%DRF%" %DRTARGET% __ndbpart.DSF -v3
        if errorlevel 1 (
            popd
            del "%DR%\__ndbpart.*" 2>nul
            echo ERROR: DRF failed compiling PART%%N\!PGAME!.DSF - check the source
            pause
            goto :part_fail
        )
        REM pre-clean stale 0.XMB - see the same-shaped comment in
        REM lib\ddb.bat for why (%DR% is shared across every compile).
        del "%DR%\0.XMB" 2>nul
        "%PHP%" "%DRB%" %DRTARGET% EN __ndbpart.json __ndbpart.DDB
        if errorlevel 1 (
            popd
            del "%DR%\__ndbpart.*" 2>nul
            echo ERROR: DRB failed building part %%N's DDB
            pause
            goto :part_fail
        )
        popd
        for %%A in ("%DR%\__ndbpart.DDB") do set "DDBSZ=%%~zA"
        if !DDBSZ! GTR 131072 (
            del "%DR%\__ndbpart.*" 2>nul
            echo ERROR: GAME%%N.DDB is !DDBSZ! bytes, over the 131072 limit
            pause
            goto :part_fail
        )
        move /Y "%DR%\__ndbpart.DDB" "RELEASE\GAME%%N.DDB" >nul
        del "%DR%\__ndbpart.DSF" "%DR%\__ndbpart.json" "%DR%\__ndbpart.___" 2>nul
        echo   DDB !DDBSZ! bytes -^> RELEASE\GAME%%N.DDB
        if not exist "RELEASE\PART%%N" md "RELEASE\PART%%N"
        if exist "%DR%\0.XMB" (
            copy /Y "%DR%\0.XMB" "RELEASE\PART%%N\0.XMB" >nul || (
                echo ERROR: could not stage 0.XMB into RELEASE\PART%%N
                pause
                goto :part_fail
            )
            echo   XMB -^> RELEASE\PART%%N\0.XMB
        )
        set "PCOUNT=0"
        for %%F in ("PART%%N\*") do (
            if /I not "%%~xF"==".DSF" (
                copy /Y "%%F" "RELEASE\PART%%N\" >nul
                if errorlevel 1 (
                    echo ERROR: could not stage %%F into RELEASE\PART%%N
                    pause
                    goto :part_fail
                )
                set /a PCOUNT+=1
            )
        )
        echo   !PCOUNT! asset^(s^) staged -^> RELEASE\PART%%N\
    )
)
REM      Every failure inside the loop above ends its block with
REM      "goto :part_fail" rather than "exit /b 1" - see the exit-code
REM      note above the classic-charset loop for why an "exit /b 1"
REM      buried in a nested block returns 0 to the caller. Each site
REM      still does its own popd/del cleanup before the goto, so
REM      pushd/popd stays balanced and %DR% is left clean on every path.
goto :parts_done
:part_fail
exit /b 1
:parts_done

echo BUILD OK: RELEASE\ is ready to copy to an SD card
if "%RUN%"=="1" call "%~dp0RUN.BAT"
endlocal
exit /b 0
