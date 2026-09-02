@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM gfx2next behavior (verified against the vendored v1.1.24):
REM  - it requires a paletted 8-bit PNG (<=256 colours); truecolour is rejected.
REM  - it takes ONLY an input path and writes <inputbase>.nxi to the CURRENT
REM    directory (it does not accept an output path). With -zx0 it writes
REM    <inputbase>.nxi.zx0 instead (no plain .nxi is left).
REM So: run gfx2next, then MOVE the produced file to RELEASE with the mode-
REM correct name (.NX2 for 320-wide, .NXI for 256-wide, +.zx0 when compressed).
set "ZX0="
set "ZSUF="
if "%COMPRESS%"=="1" ( set "ZX0=-zx0" & set "ZSUF=.zx0" )

if not exist "IMAGES" (
    echo   no IMAGES\ - skipping graphics
    goto :title_readymade
)
if not exist "%GFX%" (
    echo ERROR: gfx2next not found at %GFX% - install Gfx2Next, or set GFXDIR in CONFIG.BAT to an existing install
    exit /b 1
)
set "COUNT=0"
for %%F in ("IMAGES\*.png") do (
    REM POINTER.png/POINTER1..9.png are mouse-pointer art (16x16 sprites,
    REM converted separately below - SP18), not numbered location pictures;
    REM excluded here so they do not fail this loop's 320/256-wide check.
    set "ISPOINTER="
    for %%Q in (POINTER.png POINTER1.png POINTER2.png POINTER3.png POINTER4.png POINTER5.png POINTER6.png POINTER7.png POINTER8.png POINTER9.png) do (
        if /I "%%~nxF"=="%%Q" set "ISPOINTER=1"
    )
    if /I not "%%~nxF"=="DAAD.png" if not defined ISPOINTER (
        set "NUM="
        set "MODE="
        for /f "tokens=1,2" %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -File "lib\pnginfo.ps1" "%%~fF"') do (
            set "NUM=%%A"
            set "MODE=%%B"
        )
        if not defined MODE (
            echo ERROR: %%~nxF - !NUM! ^(expected a 320 or 256 wide PNG named with a picture number^)
            exit /b 1
        )
        REM gfx2next writes to CWD by input basename; clear any stale output first.
        del "%%~nF.nxi" "%%~nF.nxi.zx0" 2>nul
        "%GFX%" -bitmap -pal-embed !ZX0! "IMAGES\%%~nxF" >nul 2>&1
        if errorlevel 1 (
            echo ERROR: gfx2next failed on %%~nxF - must be a paletted 8-bit PNG ^(max 256 colours^)
            del "%%~nF.nxi" "%%~nF.nxi.zx0" 2>nul
            exit /b 1
        )
        if not exist "%%~nF.nxi!ZSUF!" (
            echo ERROR: gfx2next produced no output for %%~nxF
            exit /b 1
        )
        move /Y "%%~nF.nxi!ZSUF!" "RELEASE\!NUM!.!MODE!!ZSUF!" >nul
        REM Advisory palette audit - never fails the build. Skipped for
        REM ZX0 output, whose palette is compressed and not readable here.
        if not defined ZSUF powershell -NoProfile -ExecutionPolicy Bypass -File "lib\palcheck.ps1" "RELEASE\!NUM!.!MODE!"
        set /a COUNT+=1
        echo   image %%~nxF -^> !NUM!.!MODE!!ZSUF!
    )
)
echo   %COUNT% image^(s^) converted

REM ---- title screen (SP11): IMAGES\DAAD.png converts through the same
REM      gfx2next call as numbered art, but is never numbered - it is
REM      root-only (see ..\docs\graphics.html "Title screens") so the
REM      output keeps the DAAD basename instead of a picture number.
if exist "IMAGES\DAAD.png" (
    set "TWIDTH="
    set "TMODE="
    for /f %%W in ('powershell -NoProfile -Command "$b=[System.IO.File]::ReadAllBytes('IMAGES\DAAD.png'); ([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19]"') do set "TWIDTH=%%W"
    if "!TWIDTH!"=="320" set "TMODE=NX2"
    if "!TWIDTH!"=="256" set "TMODE=NXI"
    if not defined TMODE (
        echo ERROR: DAAD.png - width !TWIDTH! ^(expected a 320 or 256 wide PNG^)
        exit /b 1
    )
    del "DAAD.nxi" "DAAD.nxi.zx0" 2>nul
    "%GFX%" -bitmap -pal-embed !ZX0! "IMAGES\DAAD.png" >nul 2>&1
    if errorlevel 1 (
        echo ERROR: gfx2next failed on DAAD.png - must be a paletted 8-bit PNG ^(max 256 colours^)
        del "DAAD.nxi" "DAAD.nxi.zx0" 2>nul
        exit /b 1
    )
    if not exist "DAAD.nxi!ZSUF!" (
        echo ERROR: gfx2next produced no output for DAAD.png
        exit /b 1
    )
    move /Y "DAAD.nxi!ZSUF!" "RELEASE\DAAD.!TMODE!!ZSUF!" >nul
    REM Advisory palette audit, same as numbered art above - a title
    REM screen loads through the same l2_palette_load/l2_pal9_stamp path
    REM and carries exactly the same transparency hazard. Skipped for ZX0
    REM output, whose palette is compressed and not readable here.
    if not defined ZSUF powershell -NoProfile -ExecutionPolicy Bypass -File "lib\palcheck.ps1" "RELEASE\DAAD.!TMODE!"
    echo   title DAAD.png -^> DAAD.!TMODE!!ZSUF!
    set "TITLECONVERTED=1"
)

REM ---- pointer artwork (SP18): IMAGES\POINTER.png and POINTER1..9.png
REM      convert to the raw 256-byte 16x16 8bpp pattern the interpreter
REM      loads - the source-art alternative to a ready-made POINTER.SPR/
REM      POINTERn.SPR (see BUILD.BAT's ready-made mouse pointer staging;
REM      POINTERn.SPR is what MOUSE n 5 installs). -pal-std is
REM      LOAD-BEARING: without it gfx2next emits the source PNG's raw
REM      palette indices, which are indices into a palette nothing ever
REM      loads, so the pointer renders in arbitrary colours while still
REM      being exactly 256 bytes and passing every check here. -pal-none
REM      suppresses the .nxp nobody reads. Transparent pixels must be
REM      #FF00FF in the source art - verified: black -> $00, white ->
REM      $FF, #FF00FF -> $E3 (the sprite transparency index). gfx2next
REM      writes to the CWD by input basename, so clear any stale output
REM      first and MOVE the result - the same idiom the location-art
REM      loop above uses. No IMAGES\POINTER*.png is normal (a game that
REM      never switches pointers, or ships a ready-made .SPR instead)
REM      and not an error.
for %%P in ("IMAGES\POINTER.png" "IMAGES\POINTER1.png" "IMAGES\POINTER2.png" ^
            "IMAGES\POINTER3.png" "IMAGES\POINTER4.png" "IMAGES\POINTER5.png" ^
            "IMAGES\POINTER6.png" "IMAGES\POINTER7.png" "IMAGES\POINTER8.png" ^
            "IMAGES\POINTER9.png") do (
    if exist %%P (
        set "SPRSIZE="
        del "%%~nP.spr" 2>nul
        "%GFX%" -sprites -pal-std -pal-none %%P >nul 2>&1
        if errorlevel 1 (
            echo ERROR: gfx2next failed on %%~nxP - must be a paletted 8-bit 16x16 PNG
            del "%%~nP.spr" 2>nul
            exit /b 1
        )
        if not exist "%%~nP.spr" (
            echo ERROR: gfx2next produced no output for %%~nxP
            exit /b 1
        )
        REM gfx2next does not reject a wrong-sized source cleanly (a too-
        REM small image exits 0 with no output, already caught above; a
        REM too-large one exits 0 and writes >256 bytes, several sprites
        REM concatenated). The interpreter rejects anything that is not
        REM exactly 256 bytes silently, so check the byte count itself
        REM here rather than let a bad file reach RELEASE\ unremarked.
        for /f %%S in ('powershell -NoProfile -Command "([System.IO.File]::ReadAllBytes('%%~nP.spr')).Length"') do set "SPRSIZE=%%S"
        if not "!SPRSIZE!"=="256" (
            echo ERROR: %%~nxP converted to !SPRSIZE! bytes, not 256 - the source must be exactly 16x16
            del "%%~nP.spr" 2>nul
            exit /b 1
        )
        move /Y "%%~nP.spr" "RELEASE\%%~nP.SPR" >nul
        echo   pointer %%~nxP -^> RELEASE\%%~nP.SPR ^(gfx2next -sprites -pal-std^)
    )
)

REM ---- animated sprite sets (GFX n 19/20/21): IMAGES\SPRITES\NNN.png or a
REM      ready-made 8-bit NNN.spr, plus NNN.txt. PNG sheets go through
REM      gfx2next in raw index mode (-pal-none, no -pal-std) so the bytes are
REM      PLTE indices and lib\anipack.ps1 does the colour work; a .spr is
REM      passed to anipack as-is. Both for one number is an error.
if exist "IMAGES\SPRITES" (
    set "ANICOUNT=0"
    for %%F in ("IMAGES\SPRITES\*.png" "IMAGES\SPRITES\*.spr") do (
        set "ANUM="
        for /f %%A in ('powershell -NoProfile -Command "$m=[regex]::Match('%%~nF','\d+'); if($m.Success -and [int]$m.Value -le 254){'{0:D3}' -f [int]$m.Value}else{'ERR'}"') do set "ANUM=%%A"
        if "!ANUM!"=="ERR" (
            echo ERROR: %%~nxF - sprite files are named by set number, 000-254
            goto :sprites_fail
        )
        if not exist "IMAGES\SPRITES\%%~nF.txt" (
            echo ERROR: %%~nxF has no sidecar IMAGES\SPRITES\%%~nF.txt
            goto :sprites_fail
        )
        if /I "%%~xF"==".png" (
            if exist "IMAGES\SPRITES\%%~nF.spr" (
                echo ERROR: both %%~nF.png and %%~nF.spr exist in IMAGES\SPRITES - keep one
                goto :sprites_fail
            )
            del "%%~nF.spr" 2>nul
            "%GFX%" -sprites -pal-none "%%~fF" >nul 2>&1
            if errorlevel 1 (
                echo ERROR: gfx2next failed on %%~nxF - must be a paletted 8-bit PNG
                del "%%~nF.spr" 2>nul
                goto :sprites_fail
            )
            if not exist "%%~nF.spr" (
                echo ERROR: gfx2next produced no output for %%~nxF - is the sheet at least 16x16?
                goto :sprites_fail
            )
            powershell -NoProfile -ExecutionPolicy Bypass -File "lib\anipack.ps1" -Spr "%%~nF.spr" -Txt "IMAGES\SPRITES\%%~nF.txt" -Out "RELEASE\!ANUM!.ANI" -Png "%%~fF"
            set "ANIRC=!errorlevel!"
            del "%%~nF.spr" 2>nul
            if not "!ANIRC!"=="0" goto :sprites_fail
        ) else (
            powershell -NoProfile -ExecutionPolicy Bypass -File "lib\anipack.ps1" -Spr "%%~fF" -Txt "IMAGES\SPRITES\%%~nF.txt" -Out "RELEASE\!ANUM!.ANI"
            if errorlevel 1 goto :sprites_fail
        )
        set /a ANICOUNT+=1
    )
    echo   !ANICOUNT! sprite set^(s^) packed
)
goto :sprites_done
:sprites_fail
exit /b 1
:sprites_done

:title_readymade
REM ---- ready-made title: no IMAGES\DAAD.png (or no IMAGES\ at all) - a
REM      pre-converted DAAD.NX2/DAAD.NXI, or a ZX0 variant/8.3 synonym, in
REM      the kit folder root is staged to RELEASE\ as-is (authors with
REM      already-converted art). The IMAGES\DAAD.png conversion above wins
REM      if both exist. Probe order matches the interpreter's own title
REM      probe (compressed variants first).
if not defined TITLECONVERTED (
    set "TFOUND="
    for %%T in (DAAD.NX2.ZX0 DAAD.N2Z DAAD.NX2 DAAD.NXI.ZX0 DAAD.NXZ DAAD.NXI) do (
        if not defined TFOUND if exist "%%T" set "TFOUND=%%T"
    )
    if defined TFOUND (
        copy /Y "!TFOUND!" "RELEASE\!TFOUND!" >nul
        REM Advisory palette audit. Staged as-is means the kit never saw
        REM the source art, so this is the ONLY check these files get.
        REM Only the two uncompressed names have a readable palette; the
        REM ZX0 variants (.ZX0/.N2Z/.NXZ) cannot be audited at all.
        if /I "!TFOUND!"=="DAAD.NX2" powershell -NoProfile -ExecutionPolicy Bypass -File "lib\palcheck.ps1" "RELEASE\!TFOUND!"
        if /I "!TFOUND!"=="DAAD.NXI" powershell -NoProfile -ExecutionPolicy Bypass -File "lib\palcheck.ps1" "RELEASE\!TFOUND!"
        echo   title !TFOUND! -^> RELEASE\!TFOUND! ^(ready-made, staged as-is^)
    )
)

REM ---- ready-made numbered pictures: a pre-converted NNN.NX2/NNN.NXI,
REM      or a ZX0 variant or its 8.3 synonym, dropped into IMAGES\ is
REM      staged to RELEASE\ as-is - the ready-made counterpart to the
REM      IMAGES\*.png conversion at the top of this script, for authors
REM      whose converter writes .NX2/.NXI directly rather than a PNG.
REM      IMAGES\ and not the kit folder root: the root is the TITLE's
REM      home because a title is root-only, while numbered art belongs
REM      beside the numbered source art it stands in for. RELEASE\ is
REM      not a place to put them either - BUILD.BAT wipes RELEASE\*.NX2
REM      and every other picture extension at the start of every build.
REM      Extensions are probed in the interpreter's own gfxExtTab order
REM      (src\overlay2.asm) - compressed before raw, the Gfx2Next double
REM      extension before its 8.3 synonym - and exactly ONE file is
REM      staged per number, so the file this build reports is the file
REM      the interpreter opens. An IMAGES\NNN.png converted above WINS
REM      over a ready-made of the same number, the same rule the
REM      ready-made title follows.
if not exist "IMAGES" goto :pictures_done
for %%E in (NX2.ZX0 N2Z NX2 NXI.ZX0 NXZ NXI) do (
    for %%F in ("IMAGES\*.%%E") do (
        call :stage_picture "%%~nxF" %%E
        if errorlevel 1 goto :pictures_fail
    )
)
goto :pictures_done
REM      The loop above ends its only failure path with "goto
REM      :pictures_fail" rather than an "exit /b 1" inside the block -
REM      see BUILD.BAT's note above its classic-charset loop for why an
REM      "exit /b 1" buried in a nested block returns 0 to the caller.
REM      The subroutine's own "exit /b 1" is at ITS top level, so it
REM      reaches this loop as a real errorlevel.
:pictures_fail
exit /b 1
:pictures_done
endlocal
exit /b 0

REM ---- :stage_picture <filename> <extension>
REM      One ready-made picture file from IMAGES\. Returns 1 only for a
REM      name this staging cannot place; every other outcome (staged,
REM      already covered, beaten by a PNG) returns 0.
:stage_picture
set "RMNAME=%~1"
set "RMEXT=%~2"
REM Number = everything before the FIRST dot, so the two double
REM extensions (NX2.ZX0/NXI.ZX0) split the same way as the single ones.
set "RMNUM="
for /f "delims=." %%A in ("%RMNAME%") do set "RMNUM=%%A"
if not defined RMNUM goto :stage_picture_bad
if not "%RMNUM:~3%"=="" goto :stage_picture_bad
REM Digits only - same findstr test lib\video.bat applies to VIDEO\*.vid.
echo %RMNUM%| findstr /R "^[0-9][0-9]*$" >nul || goto :stage_picture_bad
REM Pad to the 3 digits the interpreter probes with (gfxName is exactly
REM "NNN.EXTENSION"), so 1.NX2 loads as picture 1 like 1.png does.
set "RMNUM=00%RMNUM%"
set "RMNUM=%RMNUM:~-3%"
REM Already settled this number - an earlier, higher-priority extension
REM won it on a previous pass of the probe loop.
if defined RMDONE_%RMNUM% exit /b 0
REM An IMAGES\NNN.png converted above wins. Its output is the only
REM thing in RELEASE\ under this number at this point (BUILD.BAT wiped
REM every picture extension before the build started, and no ready-made
REM has been staged for this number or the check above would have
REM returned), so its presence IS the "a PNG of this number converted
REM this run" signal - and the two names below are the only two the
REM conversion loop can have written.
if exist "RELEASE\%RMNUM%.NX2%ZSUF%" goto :stage_picture_png
if exist "RELEASE\%RMNUM%.NXI%ZSUF%" goto :stage_picture_png
copy /Y "IMAGES\%RMNAME%" "RELEASE\%RMNUM%.%RMEXT%" >nul
REM Advisory palette audit, same as the converted art and the ready-made
REM title above. Staged as-is means the kit never saw the source art, so
REM this is the ONLY check these files get. Only the two uncompressed
REM extensions have a readable palette; the ZX0 variants (.NX2.ZX0/
REM .N2Z/.NXI.ZX0/.NXZ) cannot be audited at all.
if /I "%RMEXT%"=="NX2" powershell -NoProfile -ExecutionPolicy Bypass -File "lib\palcheck.ps1" "RELEASE\%RMNUM%.%RMEXT%"
if /I "%RMEXT%"=="NXI" powershell -NoProfile -ExecutionPolicy Bypass -File "lib\palcheck.ps1" "RELEASE\%RMNUM%.%RMEXT%"
set "RMDONE_%RMNUM%=1"
echo   picture %RMNAME% -^> RELEASE\%RMNUM%.%RMEXT% ^(ready-made, staged as-is^)
exit /b 0
:stage_picture_png
set "RMDONE_%RMNUM%=1"
exit /b 0
:stage_picture_bad
echo ERROR: IMAGES\%RMNAME% - not a picture number ^(a ready-made picture is NNN.NX2 or NNN.NXI, or a compressed NNN.NX2.ZX0/NNN.N2Z/NNN.NXI.ZX0/NNN.NXZ; a ready-made title screen belongs in the kit folder root as DAAD.*^)
exit /b 1
