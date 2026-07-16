# Compiles tests\test.dsf (template), tests\condacts.dsf (suite) and
# tests\doallnest.dsf (DOALL depth/error demo) with DRC (version 2
# DDB), generates corrupt/oversize variants from the template, prints
# a header report. -Suite makes the suite DDB the active sd\GAME.DDB;
# -Err4 makes the doallnest DDB active instead (deliberate error 4:
# nested DOALL on the same process); -Rab compiles tools\Rabenstein-
# master\rabenstein.dsf (the real commercial-quality DAAD game, the
# SP4 milestone) and makes that DDB active instead. The switches are
# mutually exclusive - if more than one is given, whichever copy runs
# last in this script wins: -Suite copies first, -Err4 copies over
# it, and -Rab copies last of all, since its block comes after -Err4's.
# The template is active if no switch is given.
param([switch]$Suite, [switch]$Err4, [switch]$Rab)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$dr = Join-Path $root 'tools\DAAD-READY'

Copy-Item "$PSScriptRoot\test.dsf" "$dr\NDTEST.DSF" -Force
Push-Location $dr
try {
    & .\TOOLS\DRC\DRF.exe zx next NDTEST.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDTEST.json NDTEST.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed" }
    Move-Item NDTEST.DDB "$root\sd\GAME.DDB" -Force
}
finally {
    Remove-Item "$dr\NDTEST.DSF", "$dr\NDTEST.json" -ErrorAction SilentlyContinue
    Pop-Location
}

& "$PSScriptRoot\check-cprops.ps1"

New-Item -ItemType Directory -Force "$root\tests\out" | Out-Null

Copy-Item "$PSScriptRoot\condacts.dsf" "$dr\NDSUITE.DSF" -Force
Push-Location $dr
try {
    & .\TOOLS\DRC\DRF.exe zx next NDSUITE.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (suite)" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDSUITE.json NDSUITE.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (suite)" }
    Move-Item NDSUITE.DDB "$root\tests\out\condacts.ddb" -Force
}
finally {
    Remove-Item "$dr\NDSUITE.DSF", "$dr\NDSUITE.json" -ErrorAction SilentlyContinue
    Pop-Location
}

Copy-Item "$PSScriptRoot\doallnest.dsf" "$dr\NDNEST.DSF" -Force
Push-Location $dr
try {
    & .\TOOLS\DRC\DRF.exe zx next NDNEST.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (doallnest)" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDNEST.json NDNEST.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (doallnest)" }
    Move-Item NDNEST.DDB "$root\tests\out\doallnest.ddb" -Force
}
finally {
    Remove-Item "$dr\NDNEST.DSF", "$dr\NDNEST.json" -ErrorAction SilentlyContinue
    Pop-Location
}

$good = [System.IO.File]::ReadAllBytes("$root\sd\GAME.DDB")

$bad = [byte[]]$good.Clone()
$bad[0] = 9                                  # wrong version byte
[System.IO.File]::WriteAllBytes("$root\tests\out\corrupt.ddb", $bad)

$big = New-Object byte[] (140kb)             # over the 128K cap
[System.Array]::Copy($good, $big, $good.Length)
[System.IO.File]::WriteAllBytes("$root\tests\out\oversize.ddb", $big)

if ($Suite) {
    Copy-Item "$root\tests\out\condacts.ddb" "$root\sd\GAME.DDB" -Force
}
if ($Err4) {
    Copy-Item "$root\tests\out\doallnest.ddb" "$root\sd\GAME.DDB" -Force
}

$rabActive = $false
if ($Rab) {
    Copy-Item "$root\tools\Rabenstein-master\rabenstein.dsf" "$dr\NDRAB.DSF" -Force
    Copy-Item "$root\tools\Rabenstein-master\MLV_NEXT.BIN" "$dr\MLV_NEXT.BIN" -Force
    Push-Location $dr
    try {
        # Rabenstein's DSF was built against an older DRC that still treated
        # the MALUVA X-condacts as live. The DRC bundled here (TOOLS\DRC)
        # rejects them - DRB.PHP hard-errors (exit 2) on XPICTURE/XSAVE/
        # XLOAD/XNEXTCLS/XNEXTRST, and DRF doesn't even recognise XNEXTSPEED
        # as a token. Patch the local copy only (never
        # tools\Rabenstein-master\rabenstein.dsf) before compiling.
        #
        # Re-map every X-condact to its MALUVA EXTERN equivalent (one table
        # below). This is a semantic fix, not just a compile fix: EXTERN is
        # an ACTION (h_extern -> extVec -> ext_stub -> h_unimpl; the stub's
        # CF is ignored for actions) so an unimplemented X-condact NO-OPS and
        # the entry CONTINUES. The prior mapping used real condacts (XPICTURE
        # -> PICTURE/DISPLAY, XSAVE -> SAVE, XLOAD -> LOAD); wrong, because
        # PICTURE is a CONDITION-typed stub here (h_unimpl returns CF set) and
        # so ABORTED the whole entry - the MESSAGE 14 intro and every
        # post-move picture-redraw chain silently died.
        #
        # EXTERN function numbers (arg count per each condact's real use in
        # this DSF; all route through extVec's 16 stub slots to h_unimpl):
        #   XPICTURE x   -> EXTERN x 0    standard MALUVA
        #   XSAVE 0      -> SAVE 0       real condact since SP5 (action
        #                                 for action, prompts like MALUVA)
        #   XLOAD 0      -> LOAD 0       real condact since SP5
        #   XNEXTSPEED n -> EXTERN n 8    next-only, unused stub vector 8
        #   XNEXTCLS     -> EXTERN 0 9    next-only, 0-arg, stub vector 9
        #   XNEXTRST     -> EXTERN 0 10   next-only, 0-arg, stub vector 10
        #   XSPLITSCR n  -> EXTERN n 11   c64/cpc-only (dead for "next", but
        #                                 mapped so no X-condact token
        #                                 survives the grep gate); vector 11
        # (STUB markers at runtime will read as EXTERN vectors 0/8/9/10/11;
        # SAVE/LOAD stubs only if the player types SAVE/LOAD, which now stay
        # real SAVE/LOAD verbs untouched by this table.)
        $content = [System.IO.File]::ReadAllText("$dr\NDRAB.DSF")

        $content = [regex]::Replace($content, '\bXPICTURE[ \t]+(\S+)',   'EXTERN $1 0')
        $content = [regex]::Replace($content, '\bXSAVE[ \t]+(\S+)',      'SAVE $1')
        $content = [regex]::Replace($content, '\bXLOAD[ \t]+(\S+)',      'LOAD $1')
        $content = [regex]::Replace($content, '\bXNEXTSPEED[ \t]+(\S+)', 'EXTERN $1 8')
        $content = [regex]::Replace($content, '\bXSPLITSCR[ \t]+(\S+)',  'EXTERN $1 11')
        $content = $content -replace '\bXNEXTCLS\b', 'EXTERN 0 9'
        $content = $content -replace '\bXNEXTRST\b', 'EXTERN 0 10'

        # Fail loudly if any X-condact token slipped through (whole family,
        # not just the ones above): a survivor means DRF/DRB will abort or an
        # entry silently mis-behaves.
        $xLeft = [regex]::Matches($content, '\bX(PICTURE|SAVE|LOAD|PART|MES|MESSAGE|BEEP|PLAY|UNDONE|SPLITSCR|NEXTSPEED|NEXTCLS|NEXTRST)\b')
        if ($xLeft.Count -ne 0) {
            $names = ($xLeft | ForEach-Object { $_.Value } | Select-Object -Unique) -join ', '
            throw "Rabenstein patch: $($xLeft.Count) X-condact(s) still present after remap: $names"
        }

        [System.IO.File]::WriteAllText("$dr\NDRAB.DSF", $content)

        & .\TOOLS\DRC\DRF.exe zx next NDRAB.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (rabenstein)" }
        & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDRAB.json NDRAB.DDB
        if ($LASTEXITCODE -ne 0) { throw "DRB failed (rabenstein)" }
        Copy-Item NDRAB.DDB "$root\tests\out\rabenstein.ddb" -Force
        try {
            Copy-Item NDRAB.DDB "$root\sd\GAME.DDB" -Force
            Remove-Item NDRAB.DDB -ErrorAction SilentlyContinue
            $rabActive = $true
        }
        catch {
            "WARNING: could not copy to sd\GAME.DDB (likely locked by a running CSpect - close it and copy $dr\NDRAB.DDB across manually): $_"
        }
    }
    finally {
        Remove-Item "$dr\NDRAB.DSF", "$dr\NDRAB.json", "$dr\NDRAB.___", "$dr\MLV_NEXT.BIN" -ErrorAction SilentlyContinue
        Pop-Location
    }
}

$good = [System.IO.File]::ReadAllBytes("$root\sd\GAME.DDB")

"size=$($good.Length) (hex $('{0:X4}' -f $good.Length))"
"version=$($good[0]) target=$('{0:X2}' -f $good[1]) magic=$($good[2])"
$ptrs = for ($i = 8; $i -lt 34; $i += 2) { '{0:X4}' -f ($good[$i] + 256 * $good[$i+1]) }
"pointers: $($ptrs -join ' ')"
if ($rabActive) { "active: rabenstein" }
elseif ($Rab) { "active: rabenstein (sd\GAME.DDB copy failed, see warning above - stale DDB still active)" }
elseif ($Err4) { "active: doallnest (E04 demo)" }
elseif ($Suite) { "active: suite" }
else { "active: template" }
