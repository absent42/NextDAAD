@echo off
setlocal EnableExtensions
REM Compile one .DSF into a DDB with lib\ndrc.exe.
REM
REM   %1  DDB destination file      - default RELEASE\GAME.DDB
REM   %2  0.XMB destination folder  - default RELEASE
REM
REM GAME arrives in the environment from BUILD.BAT and is the .DSF path
REM without its extension, relative to the kit root: "STARTER" for the
REM main game, "PART2\SECONDHALF" for a part. Both callers run with CWD =
REM kit root, so every path here is relative to it.
REM
REM No pause on the error paths - ddb.bat's callers pause.
set "DDBOUT=%~1"
if not defined DDBOUT set "DDBOUT=RELEASE\GAME.DDB"
set "XMBDIR=%~2"
if not defined XMBDIR set "XMBDIR=RELEASE"
if not exist "%XMBDIR%" md "%XMBDIR%"

REM ---- pre-clean 0.XMB, both landing spots -----------------------------
REM ndrc writes 0.XMB into the CURRENT directory (measured), never beside
REM the output DDB wherever that is sent. It writes one only when the
REM source uses XMESSAGE/XMES, so a game without external text must not
REM inherit a leftover from the previous compile - the kit root and the
REM destination are both cleared before the run.
del "0.XMB" 2>nul
del "%XMBDIR%\0.XMB" 2>nul

REM -v3 compiles a DAAD version 3 database. Owner ruling 2026-08-01. The
REM interpreter accepts version 2 and 3 alike, so this is a dialect
REM choice, not a requirement: -v3 unlocks second-parameter indirection
REM (LET 100 @101), GETKEY, native XMES and the V3 flag 53 bits. Three
REM things change silently in a game written for version 2 - SYNONYM
REM stops marking DONE, PAUSE 0 becomes "wait for a key", and flag 53
REM bit 1 starts switching the HASAT attribute bank. See
REM ..\docs\daad-v3.html, "Moving an existing version 2 game to V3".
REM
REM ndrc prints its own diagnostics, so they are left on screen rather
REM than swallowed - that includes its refusal of #classic, which the
REM NEXTDAAD target rejects outright (a classic-mode database targets the
REM original pre-DRC DAAD interpreters, and those cannot read a NextDAAD
REM database at all - it only makes the file bigger here).
REM -auto-tokens selects compression tokens from the game's own text
REM instead of the builtin English table and encodes with an optimal
REM parse - smaller DDBs, especially for prose-heavy games. The DDB
REM stays format-identical. A hand-written .tok beside the source is
REM ignored while this flag is set (ndrc prints a notice naming it).
"%NDRC%" %DRTARGET% EN "%GAME%.DSF" "%DDBOUT%" -v3 -auto-tokens
if errorlevel 1 (
    del "%DDBOUT%" 2>nul
    del "0.XMB" 2>nul
    echo ERROR: ndrc failed compiling %GAME%.DSF - see the message above
    exit /b 1
)

REM Guard the size test below: %%~zA on a missing file yields an empty
REM string, which turns "if %DDBSZ% GTR" into a cmd syntax error rather
REM than a diagnosis.
if not exist "%DDBOUT%" (
    del "0.XMB" 2>nul
    echo ERROR: ndrc reported success but wrote no %DDBOUT%
    exit /b 1
)
for %%A in ("%DDBOUT%") do set "DDBSZ=%%~zA"
if %DDBSZ% GTR 65535 (
    del "%DDBOUT%" 2>nul
    del "0.XMB" 2>nul
    echo ERROR: %DDBOUT% is %DDBSZ% bytes, over the 65535 limit
    exit /b 1
)
echo   DDB %DDBSZ% bytes -^> %DDBOUT%

REM ---- XMESSAGE/XMES external text: present only when the source uses
REM      it, so absence is normal and not an error. Moved rather than
REM      copied, to leave no 0.XMB behind in the kit root.
if exist "0.XMB" (
    move /Y "0.XMB" "%XMBDIR%\0.XMB" >nul || (
        echo ERROR: could not stage 0.XMB into %XMBDIR%
        exit /b 1
    )
    echo   XMB -^> %XMBDIR%\0.XMB
)
endlocal
exit /b 0
