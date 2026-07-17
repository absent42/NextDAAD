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
"%DRF%" zx next __ndb.DSF
if errorlevel 1 (
    popd
    del "%DR%\__ndb.*" 2>nul
    echo ERROR: DRF failed compiling %GAME%.DSF - check the source
    exit /b 1
)
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
endlocal
exit /b 0
