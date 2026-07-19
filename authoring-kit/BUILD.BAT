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
set "DRB=%DR%\TOOLS\DRC\DRB.PHP"
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
if not exist "RELEASE" md "RELEASE"
del /Q "RELEASE\*.NX2" "RELEASE\*.NXI" "RELEASE\*.ZX0" "RELEASE\*.zx0" "RELEASE\*.N2Z" "RELEASE\*.NXZ" "RELEASE\*.AKY" "RELEASE\*.AYS" "RELEASE\GAME.SFB" "RELEASE\GAME.DDB" "RELEASE\FONT.CHR" 2>nul
REM ---- remove stale multi-part output too, so a part removed since the
REM      last build (its PART<n> folder deleted) cannot leave a stray
REM      GAME<n>.DDB or PART<n>\ behind on the SD card - see SETUP.md's
REM      multi-part games section, "no stray GAME<n>.D* files" warning.
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

call "%~dp0lib\assemble.bat"
if errorlevel 1 ( pause & exit /b 1 )

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
            exit /b 1
        )
        echo Building part %%N ^(!PGAME!^) ...
        copy /Y "PART%%N\!PGAME!.DSF" "%DR%\__ndbpart.DSF" >nul || (
            echo ERROR: could not stage PART%%N\!PGAME!.DSF into %DR%
            pause
            exit /b 1
        )
        pushd "%DR%"
        "%DRF%" zx next __ndbpart.DSF
        if errorlevel 1 (
            popd
            del "%DR%\__ndbpart.*" 2>nul
            echo ERROR: DRF failed compiling PART%%N\!PGAME!.DSF - check the source
            pause
            exit /b 1
        )
        REM pre-clean stale 0.XMB - see the same-shaped comment in
        REM lib\ddb.bat for why (%DR% is shared across every compile).
        del "%DR%\0.XMB" 2>nul
        "%PHP%" "%DRB%" zx next EN __ndbpart.json __ndbpart.DDB
        if errorlevel 1 (
            popd
            del "%DR%\__ndbpart.*" 2>nul
            echo ERROR: DRB failed building part %%N's DDB
            pause
            exit /b 1
        )
        popd
        for %%A in ("%DR%\__ndbpart.DDB") do set "DDBSZ=%%~zA"
        if !DDBSZ! GTR 131072 (
            del "%DR%\__ndbpart.*" 2>nul
            echo ERROR: GAME%%N.DDB is !DDBSZ! bytes, over the 131072 limit
            pause
            exit /b 1
        )
        move /Y "%DR%\__ndbpart.DDB" "RELEASE\GAME%%N.DDB" >nul
        del "%DR%\__ndbpart.DSF" "%DR%\__ndbpart.json" "%DR%\__ndbpart.___" 2>nul
        echo   DDB !DDBSZ! bytes -^> RELEASE\GAME%%N.DDB
        if not exist "RELEASE\PART%%N" md "RELEASE\PART%%N"
        if exist "%DR%\0.XMB" (
            copy /Y "%DR%\0.XMB" "RELEASE\PART%%N\0.XMB" >nul || (
                echo ERROR: could not stage 0.XMB into RELEASE\PART%%N
                pause
                exit /b 1
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
                    exit /b 1
                )
                set /a PCOUNT+=1
            )
        )
        echo   !PCOUNT! asset^(s^) staged -^> RELEASE\PART%%N\
    )
)

echo BUILD OK: RELEASE\ is ready to copy to an SD card
if "%RUN%"=="1" call "%~dp0RUN.BAT"
endlocal
exit /b 0
