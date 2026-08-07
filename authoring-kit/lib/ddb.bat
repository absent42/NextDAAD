@echo off
setlocal EnableExtensions
REM DRF/DRB must run with CWD = DAAD-READY (they read ASSETS\ relatively),
REM so stage the DSF there, compile, then move the DDB back out.
REM DR/DRF/PHP/DRB arrive from BUILD.BAT as paths relative to the caller's
REM CWD (authoring-kit). Resolve them to absolute paths now, before the
REM pushd below changes CWD to DR - otherwise these same relative strings
REM would resolve against the wrong directory once we are inside it.
for %%I in ("%DR%") do set "DR=%%~fI"
for %%I in ("%DRF%") do set "DRF=%%~fI"
for %%I in ("%PHP%") do set "PHP=%%~fI"
for %%I in ("%DRB%") do set "DRB=%%~fI"
copy /Y "%GAME%.DSF" "%DR%\__ndb.DSF" >nul || (
    echo ERROR: could not stage %GAME%.DSF into %DR%
    exit /b 1
)
pushd "%DR%"
REM -v3 compiles a DAAD version 3 database, matching DAAD-READY's own
REM ZXNEXT.BAT. Owner ruling 2026-08-01. The interpreter accepts
REM version 2 and 3 alike, so this is a dialect choice, not a
REM requirement: -v3 unlocks second-parameter indirection (LET 100
REM @101), GETKEY, native XMES and the V3 flag 53 bits. Three things
REM change silently in a game written for version 2 - SYNONYM stops
REM marking DONE, PAUSE 0 becomes "wait for a key", and flag 53 bit 1
REM starts switching the HASAT attribute bank. See ..\docs\daad-v3.html,
REM "Moving an existing version 2 game to V3". The per-part compile in BUILD.BAT must
REM carry the same flag - both sites or neither.
"%DRF%" zx next __ndb.DSF -v3
if errorlevel 1 (
    popd
    del "%DR%\__ndb.*" 2>nul
    echo ERROR: DRF failed compiling %GAME%.DSF - check the source
    exit /b 1
)
REM ---- pre-clean stale 0.XMB from a previous compile - %DR% is shared
REM      across builds, so a game without XMESSAGE must not inherit and
REM      stage a leftover 0.XMB left behind by a different game.
del "%DR%\0.XMB" 2>nul
"%PHP%" "%DRB%" zx next EN __ndb.json __ndb.DDB
if errorlevel 1 (
    popd
    del "%DR%\__ndb.*" 2>nul
    echo ERROR: DRB failed building the DDB
    exit /b 1
)
popd
for %%A in ("%DR%\__ndb.DDB") do set "DDBSZ=%%~zA"
if %DDBSZ% GTR 131072 (
    del "%DR%\__ndb.*" 2>nul
    echo ERROR: GAME.DDB is %DDBSZ% bytes, over the 131072 limit
    exit /b 1
)
move /Y "%DR%\__ndb.DDB" "RELEASE\GAME.DDB" >nul
del "%DR%\__ndb.DSF" "%DR%\__ndb.json" "%DR%\__ndb.___" 2>nul
echo   DDB %DDBSZ% bytes -^> RELEASE\GAME.DDB
REM ---- XMESSAGE/XMES external text: DRB writes 0.XMB into %DR% only
REM      when the DSF uses XMESSAGE/XMES - absence is normal, not an
REM      error, so stage it only when present.
if exist "%DR%\0.XMB" (
    copy /Y "%DR%\0.XMB" "RELEASE\0.XMB" >nul || (
        echo ERROR: could not stage 0.XMB into RELEASE
        exit /b 1
    )
    echo   XMB -^> RELEASE\0.XMB
)
endlocal
exit /b 0
