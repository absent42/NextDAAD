# Layer 2 TRANSPARENCY / punch-out fixture - standalone stager.
#
# Compiles tests\l2holes.dsf, generates the punch-out card with
# tests\art\mkl2holes.py, checks both, and stages sd\L2HOLES\ - one
# folder to copy to the card, one file to launch.
#
#     .\tests\stage-l2holes.ps1
#
# WHY THIS IS NOT A SWITCH IN tests\build-tests.ps1. It deliberately does
# not touch that script: this is an owner instrument with one leg and no
# shared staging, and build-tests.ps1 is under review by other work. If
# this fixture ever earns a permanent place it can be folded in as
# -L2Holes, mirroring the -SfxDi block this script is modelled on.
#
# THE TOOLCHAIN IS RUN OUT OF TREE, and that is the one deliberate
# difference from build-tests.ps1. That script copies each DSF INTO
# tools\DAAD-READY and compiles with the cwd set there; tools\ is
# read-only working material that git cannot restore, so this script
# instead runs DRF.exe and DRB.PHP by absolute path with the cwd set to
# tests\out\l2holes-work and writes nothing under tools\ at all. The
# result is byte-identical: DRF takes the DSF path as an argument, and
# DRB's default compression tokens are embedded in the PHP (drb.php's
# $compressionJSON_EN), read from an external file only when a
# <name>.tok sits next to the input - which is true in neither location.
#
# EVERY CHECK BELOW IS A REFUSAL, NOT A WARNING. A partially staged
# folder is worse than none: a missing 001.NXI makes PICTURE fail, and
# the fixture would then be reporting on staging rather than on Layer 2.
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot
$sd = Join-Path $root 'sd'
$legName = 'L2HOLES'
$leg = Join-Path $sd $legName
$work = Join-Path $root 'tests\out\l2holes-work'
$drc = Join-Path $root 'tools\DAAD-READY\TOOLS\DRC'
$php = Join-Path $root 'tools\DAAD-READY\PHP\php.exe'

# ---- the CSpect lock guard, before anything is written -------------
# Same hazard the -Aud / -AudLad / -SfxDi blocks guard: a running
# emulator holds sd\ files open, the copies fail one at a time, and what
# is left behind is a fixture that boots and tests nothing. build-tests
# throws here rather than warning, and so does this.
if (Get-Process CSpect -ErrorAction SilentlyContinue) {
    throw "CSpect is running - close it before staging (locked sd\ files leave a partial leg folder)"
}

New-Item -ItemType Directory -Force $work | Out-Null
New-Item -ItemType Directory -Force "$root\tests\out" | Out-Null
New-Item -ItemType Directory -Force $sd | Out-Null

# ---- 1. compile the fixture ---------------------------------------
# No -v3: the fixture's header version must stay 2. Nothing here depends
# on a V3 condact, and a V3 header would change SYNONYM/attribute
# semantics under a fixture whose whole value is that one thing moves.
Copy-Item "$PSScriptRoot\l2holes.dsf" "$work\NDL2HOLE.DSF" -Force
Push-Location $work
try {
    & "$drc\DRF.exe" zx next NDL2HOLE.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (l2holes)" }
    & $php "$drc\DRB.PHP" zx next EN NDL2HOLE.json NDL2HOLE.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (l2holes)" }
}
finally {
    Pop-Location
}
$ddbPath = "$work\NDL2HOLE.DDB"
if (-not (Test-Path $ddbPath)) { throw "DRB produced no NDL2HOLE.DDB" }

# ---- 2. the compiled TEXT, cell by cell ---------------------------
# The ruler is the instrument, and its column accounting is fragile in a
# way nothing downstream would notice: NextDAAD buffers non-space
# characters and flushes on a space (src\print.asm prn_char/prn_flush),
# so each MES must be exactly 15 non-space characters plus ONE trailing
# space. A trailing space eaten by an editor would silently merge two
# segments, shift every column left and re-colour the row - and the card
# would then be judged against a ruler that lies. This restates the hole
# table from tests\art\mkl2holes.py independently, so a hole that moves
# without its tag moving fails the stage instead of the run.
$json = Get-Content "$work\NDL2HOLE.json" -Raw | ConvertFrom-Json
$msgs = @{}
foreach ($m in $json.messages) { $msgs[[int]$m.Value] = [string]$m.Text }
$procs = @{}
foreach ($p in $json.processes) { $procs[[int]$p.Value] = $p.entries }

$tags = @{
    '4,1' = 'TL'; '5,1' = 'TL'; '4,8' = 'TR'; '5,8' = 'TR'
    '26,1' = 'BL'; '27,1' = 'BL'; '26,8' = 'BR'; '27,8' = 'BR'
    '15,2' = 'DG'; '16,2' = 'DG'; '17,2' = 'DG'
    '16,4' = 'CT'; '16,5' = 'CT'; '18,4' = 'CT'
    '15,6' = 'RN'; '15,7' = 'RN'; '13,6' = 'RN'
    '20,2' = '32'; '21,2' = '32'; '20,4' = '16'; '21,4' = '16'; '20,6' = '08'
    '21,3' = '4C'
    '9,3' = 'E3'; '9,4' = 'E3'; '10,3' = 'E3'; '11,4' = 'E3'
    '9,5' = 'E7'; '9,6' = 'E7'; '10,6' = 'E7'; '11,5' = 'E7'
}

$rows = @()
foreach ($tbl in 2, 3) {
    if (-not $procs.ContainsKey($tbl)) { throw "l2holes: process $tbl is missing - the ruler would be blank" }
    foreach ($e in $procs[$tbl]) {
        $texts = @()
        $inks = @()
        foreach ($c in $e.condacts) {
            if ($c.Condact -eq 'MES') { $texts += $msgs[[int]$c.Param1] }
            elseif ($c.Condact -eq 'INK') { $inks += [int]$c.Param1 }
            else { throw "l2holes: unexpected condact '$($c.Condact)' inside the ruler fill" }
        }
        if ($texts.Count -ne 5 -or $inks.Count -ne 5) {
            throw "l2holes: ruler row $($rows.Count) has $($inks.Count) INK / $($texts.Count) MES, expected 5 of each"
        }
        $rows += , @{ text = ($texts -join ''); parts = $texts; inks = $inks }
    }
}
if ($rows.Count -ne 32) { throw "l2holes: the ruler has $($rows.Count) rows, expected 32" }

for ($r = 0; $r -lt 32; $r++) {
    $row = $rows[$r]
    $last = ($r -eq 31)
    # 31 is one cell short on purpose: an 80th character there would wrap,
    # newline and scroll the whole screen up by one (win_newline,
    # src\windows.asm), destroying row 0.
    $wantLen = if ($last) { 79 } else { 80 }
    if ($row.text.Length -ne $wantLen) {
        throw "l2holes: row $r is $($row.text.Length) columns, expected $wantLen"
    }
    for ($i = 0; $i -lt 5; $i++) {
        $p = $row.parts[$i]
        $wantSeg = if ($last -and $i -eq 4) { 15 } else { 16 }
        if ($p.Length -ne $wantSeg) { throw "l2holes: row $r segment $i is $($p.Length) chars, expected $wantSeg" }
        if (-not $p.EndsWith(' ')) { throw "l2holes: row $r segment $i has no trailing space - it would not flush (see src\print.asm prn_flush)" }
        if ($p.Substring(0, $p.Length - 1).Contains(' ')) { throw "l2holes: row $r segment $i has an interior space - the column accounting assumes exactly one, at the end" }
    }
    if ($r -eq 0 -or $r -eq 31) { continue }   # legend rows, not ruler rows
    for ($u = 0; $u -lt 10; $u++) {
        $cell = $row.text.Substring(8 * $u, 8)
        $want = '{0:d2}-{1:d2}' -f $r, (8 * $u)
        if ($cell.Substring(0, 5) -ne $want) {
            throw "l2holes: row $r unit $u reads '$cell', expected it to start '$want'"
        }
        $t = $cell.Substring(5, 2)
        $key = "$r,$u"
        if ($tags.ContainsKey($key)) {
            if ($t -ne $tags[$key]) { throw "l2holes: row $r unit $u is tagged '$t', the card uncovers '$($tags[$key])' there" }
        }
        elseif ($r -lt 4 -or $r -gt 27 -or $u -eq 0 -or $u -eq 9) {
            if ($t -ne 'CM') { throw "l2holes: row $r unit $u is in the control margin but tagged '$t', not CM" }
        }
    }
}
"ruler: 32 rows x 80 columns verified from the compiled messages, $($tags.Count) hole tags on the cells the card uncovers"

# ---- 3. the compiled BYTES ----------------------------------------
# The JSON above is the front end's view. These are the bytes the
# interpreter will actually execute - checked because DRC has rewritten
# stimulus condacts under this project before.
$ddb = [System.IO.File]::ReadAllBytes($ddbPath)
if ($ddb[0] -ne 2) {
    throw "l2holes: DDB header version byte is $($ddb[0]), expected 2 - this fixture is compiled WITHOUT -v3"
}
function Find-ByteRun([byte[]]$hay, [byte[]]$needle) {
    $hits = @()
    for ($i = 0; $i -le $hay.Length - $needle.Length; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $needle.Length; $j++) { if ($hay[$i + $j] -ne $needle[$j]) { $ok = $false; break } }
        if ($ok) { $hits += $i }
    }
    return , $hits
}
$needles = @(
    @{ n = 'MODE 2 (the More... pager off - without it the fill stops at 31 lines)'; b = [byte[]]@(81, 2) },
    @{ n = 'WINSIZE 32 80 (the full-screen ruler window)'; b = [byte[]]@(107, 32, 80) },
    @{ n = 'WINAT 31 79 + WINSIZE 1 1 (the ANYKEY parking window)'; b = [byte[]]@(82, 31, 79, 107, 1, 1) },
    @{ n = 'PAPER 1 (dark blue - the binary hole detector)'; b = [byte[]]@(65, 1) },
    @{ n = 'PICTURE 1 (the card)'; b = [byte[]]@(84, 1) },
    @{ n = 'DISPLAY 0 (card up)'; b = [byte[]]@(28, 0) },
    @{ n = 'DISPLAY 1 (card cleared - the A/B reference state)'; b = [byte[]]@(28, 1) },
    @{ n = 'ANYKEY (the toggle wait)'; b = [byte[]]@(24) }
)
foreach ($s in $needles) {
    if ((Find-ByteRun $ddb $s.b).Count -lt 1) { throw "l2holes: '$($s.n)' is not present in the compiled DDB" }
}
"ddb: $($ddb.Length) bytes, v$($ddb[0]), MODE 2 / WINSIZE 32 80 / WINAT 31 79 / PAPER 1 / PICTURE 1 / DISPLAY 0 / DISPLAY 1 / ANYKEY all present"

# ---- 4. the card --------------------------------------------------
# Generated, not committed - a byte-exact function of the constants in
# tests\art\mkl2holes.py, the same rule the tones and the other generated
# fixtures follow. That script asserts its own invariants and decodes the
# file back; the checks here are the independent half, from the staging
# side, in the terms the interpreter will read it.
& python "$PSScriptRoot\art\mkl2holes.py" "$root\tests\out"
if ($LASTEXITCODE -ne 0) { throw "tests\art\mkl2holes.py failed" }
$cardSrc = "$root\tests\out\l2holes.nxi"
if (-not (Test-Path $cardSrc)) { throw "mkl2holes.py produced no l2holes.nxi" }

$card = [System.IO.File]::ReadAllBytes($cardSrc)
# gfx_derive_height (src\overlay2.asm) takes the row count from the FILE
# LENGTH alone - (bytes - 512) / 256 - and fails anything outside 1..192
# in 256-wide mode, so the size is the one thing that must be right for
# the card to load at all.
if ((($card.Length - 512) % 256) -ne 0) { throw "l2holes.nxi is $($card.Length) bytes - not 512 + a whole number of 256-byte rows" }
$cardRows = ($card.Length - 512) / 256
if ($cardRows -ne 192) { throw "l2holes.nxi derives $cardRows rows - this card must be the full-screen 192 (gfx_derive_height's mode 0 ceiling)" }

# Exactly one non-255 palette entry may pack to $E3. That entry IS the
# dodge test (see the card's header): two would make a hole ambiguous,
# none would make the E3 block a plain magenta rectangle testing nothing.
$e3 = @()
for ($i = 0; $i -lt 256; $i++) { if ($card[2 * $i] -eq 0xE3) { $e3 += $i } }
if ($e3.Count -ne 1 -or $e3[0] -ne 14) {
    throw "l2holes.nxi: palette entries packing to `$E3 are ($($e3 -join ',')), expected exactly index 14 - the dodge test is not armed"
}
if ($card[510] -eq 0xE3) {
    throw "l2holes.nxi: palette entry 255 packs to `$E3 - it must carry the bright-green stamp-failure signature instead (see the card's header)"
}

# Index 255 must be PRESENT (this card is the inverse of l2card.nxi: no
# hole at all means nothing to see through), and no index may be used
# that has no colour.
$holePixels = 0
$maxIdx = 0
for ($i = 512; $i -lt $card.Length; $i++) {
    $v = $card[$i]
    if ($v -eq 255) { $holePixels++ }
    elseif ($v -gt $maxIdx) { $maxIdx = $v }
}
if ($holePixels -lt 1) { throw "l2holes.nxi has no index-255 pixel - it would punch no holes and test nothing" }
if ($maxIdx -gt 15) { throw "l2holes.nxi uses palette index $maxIdx, which has no colour" }
"card: $($card.Length) bytes, 256x$cardRows, $holePixels transparent pixels, index 14 = the `$E3 dodge entry, entry 255 = `$$('{0:X2}' -f $card[510]) (green, must never be seen)"

# ---- 5. stage ------------------------------------------------------
# Deliberately narrow, the same shape as build-tests.ps1's Reset-LegDir:
# the name is fixed and the resolved path must sit directly under sd\, so
# the recursive delete below can never be pointed anywhere else.
if ((Split-Path -Parent $leg) -ne $sd) { throw "stage-l2holes: '$leg' is not directly under $sd" }
if (Test-Path -LiteralPath $leg) {
    Get-ChildItem -LiteralPath $leg -Force | Remove-Item -Recurse -Force
}
New-Item -ItemType Directory -Force $leg | Out-Null

Copy-Item $ddbPath "$leg\GAME.DDB" -Force
# .NXI, NOT .NX2, and it matters: gfxExtTab routes NXI to mode 0 / width
# 256 and NX2 to mode 1 / width 320, the NX2 variants are probed FIRST,
# and a 320-wide surface would cover the control margin this fixture
# depends on. sd\L2HOLES\ is emptied above and holds three files, so no
# other art of number 001 exists for the probe chain to find.
Copy-Item $cardSrc "$leg\001.NXI" -Force

$nexSrc = "$root\build\nextdaad.nex"
if (-not (Test-Path $nexSrc)) {
    throw "no build\nextdaad.nex - run .\build.ps1 first, or sd\$legName\ has no interpreter to launch"
}
Copy-Item $nexSrc "$leg\NEXTDAAD.NEX" -Force

$legFiles = @(Get-ChildItem -LiteralPath $leg -Force -File | Sort-Object Name)
$legBytes = ($legFiles | Measure-Object -Property Length -Sum).Sum
""
"=== sd\$legName\ - $($legFiles.Count) file(s), $legBytes bytes ==="
foreach ($f in $legFiles) { "  {0,-16} {1,12}" -f $f.Name, $f.Length }
"COPY   sd\$legName\  (the whole folder, to the card)"
"LAUNCH NEXTDAAD.NEX  (from inside that folder)"
"SHEET  docs\superpowers\l2-holes-run-sheet.md"
