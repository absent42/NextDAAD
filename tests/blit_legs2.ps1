# Stage blitter silicon leg 7: colour cycling and sprite animation across picture draws, then
# a sprite pattern upload and a video session after them.
#
#   sd\LEGBLT7\  Release, colour-cycle fixture with three verbs added
#
# The fixture is tests\cycle.dsf with:
#   COPY  30 front-to-back surface copies (GFX 0 1): whole-surface transfers of the largest size,
#         nothing on screen changes and no palette is written, so the marching row and the sprite
#         both show any stutter
#   PIC   30 draws of 004.NX3 (320x32 positioned picture, palette 101-150, drawn at y 96)
#   FULL  30 draws of 001.NX2 (the palette card: a whole picture with a whole palette)
# PICTURE and DISPLAY stop every sprite set, and a picture that carries a palette holds the
# palette lock while it loads (the cycle skips its steps under the lock): under PIC and FULL the
# picture alone is judged. COPY is the stutter probe.
#
#   pwsh -File tests\blit_legs2.ps1
#
# Builds Release for the leg, then DEBUG so the current build is left as DEBUG.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..").Path
$sd = Join-Path $root 'sd'
$out = Join-Path $root 'tests\out'
$work = Join-Path $out 'blt7-work'
$ndrc = if ($env:NEXTDAAD_NDRC) { $env:NEXTDAAD_NDRC } else { Join-Path $root 'authoring-kit\lib\ndrc.exe' }
$draws = 30

if (Get-Process CSpect -ErrorAction SilentlyContinue) { throw 'CSpect is running - close it before staging' }
$leg = Join-Path $sd 'LEGBLT7'
if (Test-Path $leg) { throw 'sd\LEGBLT7 exists - a leg is not re-staged; move it away first' }

function Invoke-Checked([string]$what, [scriptblock]$cmd) {
    $o = & $cmd *>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE): $($o | Select-Object -Last 6 | Out-String)" }
    $o
}

function Edit-Once([string]$text, [string]$find, [string]$with) {
    if (([regex]::Matches($text, [regex]::Escape($find))).Count -ne 1) { throw "cycle.dsf: '$find' not found exactly once" }
    $text.Replace($find, $with)
}

# ---- the fixture
New-Item -ItemType Directory -Force $work | Out-Null
$dsf = [IO.File]::ReadAllText("$PSScriptRoot\cycle.dsf") -replace "`r`n", "`n"
$dsf = Edit-Once $dsf "STOPC  55  verb`n" "STOPC  55  verb`nPIC    56  verb`nFULL   57  verb`nCOPY   58  verb`n"
$dsf = Edit-Once $dsf '/20 "verbs: VID XBN SPR FADE CYC STOPC#n"' '/20 "verbs: VID XBN SPR FADE CYC STOPC COPY PIC FULL#n"'
$dsf = Edit-Once $dsf "/25 `"S20 fade done#n`"`n" "/25 `"S20 fade done#n`"`n/26 `"PIC done#n`"`n/27 `"FULL done#n`"`n/28 `"COPY done#n`"`n"
function New-Burst([string]$verb, [int]$pic, [int]$msg) {
    $l = @("> $verb   _    PICTURE $pic", '             DISPLAY 0')
    for ($i = 1; $i -lt $draws; $i++) { $l += "             PICTURE $pic", '             DISPLAY 0' }
    $l += "             MESSAGE $msg", '             DONE'
    ($l -join "`n") + "`n"
}
$copy = "> COPY  _    GFX 0 1`n" + ("             GFX 0 1`n" * ($draws - 1)) + "             MESSAGE 28`n             DONE`n"
$dsf = Edit-Once $dsf "> _     _    MESSAGE 20`n" ($copy + (New-Burst 'PIC ' 4 26) + (New-Burst 'FULL' 1 27) + "> _     _    MESSAGE 20`n")
[IO.File]::WriteAllText("$work\BLT7.DSF", $dsf)
Push-Location $work
try { Invoke-Checked 'ndrc' { & $ndrc nextdaad EN BLT7.DSF BLT7.DDB -v3 -auto-tokens } | Out-Null }
finally { Pop-Location }
$ddb = [IO.File]::ReadAllBytes("$work\BLT7.DDB")
# PICTURE is condact 84, DISPLAY 28: each burst must sit contiguously in the DDB
function Test-Burst([int]$pic) {
    $want = [byte[]]((1..$draws) | ForEach-Object { 84, $pic, 28, 0 })
    for ($i = 0; $i -le $ddb.Length - $want.Length; $i++) {
        $j = 0
        while ($j -lt $want.Length -and $ddb[$i + $j] -eq $want[$j]) { $j++ }
        if ($j -eq $want.Length) { return $true }
    }
    $false
}
# GFX is condact 87
$want = [byte[]]((1..$draws) | ForEach-Object { 87, 0, 1 })
$hit = $false
for ($i = 0; $i -le $ddb.Length - $want.Length -and -not $hit; $i++) {
    $j = 0
    while ($j -lt $want.Length -and $ddb[$i + $j] -eq $want[$j]) { $j++ }
    $hit = ($j -eq $want.Length)
}
if (-not $hit) { throw "BLT7.DDB does not contain $draws x GFX 0 1 as compiled bytes" }
if (-not (Test-Burst 4)) { throw "BLT7.DDB does not contain $draws x PICTURE 4 / DISPLAY 0 as compiled bytes" }
if (-not (Test-Burst 1)) { throw "BLT7.DDB does not contain $draws x PICTURE 1 / DISPLAY 0 as compiled bytes" }

# ---- art: the 320x256 positioned set gives 004.NX3
$art = Join-Path $out 'blt-art1'
Invoke-Checked 'mkl2pos.py' { & python "$PSScriptRoot\art\mkl2pos.py" $art --mode 1 } | Out-Null
if (-not (Test-Path "$art\004.NX3")) { throw 'mkl2pos.py wrote no 004.NX3' }

# ---- builds; the cycle fixture's card, clip, sprite set and externs come from sd\LEGBLT5
Push-Location $root
try {
    Invoke-Checked 'build.ps1 -Release' { & "$root\build.ps1" -Release } | Out-Null
    $nexRel = Join-Path $out 'blt7-release.nex'
    Copy-Item "$root\build\nextdaad.nex" $nexRel -Force
    Invoke-Checked 'build.ps1' { & "$root\build.ps1" } | Out-Null
}
finally { Pop-Location }
$src = Join-Path $sd 'LEGBLT5'
$need = '001.NX2', '001.VID', '002.ANI', 'GAME.XBN'
foreach ($f in $need) { if (-not (Test-Path (Join-Path $src $f))) { throw "sd\LEGBLT5\$f missing - run tests\blit_legs.ps1 first" } }

New-Item -ItemType Directory -Force $leg | Out-Null
foreach ($f in $need) { Copy-Item (Join-Path $src $f) (Join-Path $leg $f) }
Copy-Item "$work\BLT7.DDB" "$leg\GAME.DDB" -Force
Copy-Item $nexRel "$leg\NEXTDAAD.NEX" -Force
Copy-Item "$art\004.NX3" "$leg\004.NX3"
"LEGBLT7: {0} files" -f @(Get-ChildItem $leg -File).Count

$idx = Join-Path $sd 'LEGBLT.TXT'
$lines = @(Get-Content $idx | Where-Object { $_ -notmatch '^LEGBLT7 ' -and $_ -notmatch '^Copy each folder' })
$lines += 'LEGBLT7  Release  colour-cycle fixture with COPY, PIC and FULL: cycling and sprites across picture draws'
$lines += 'Copy each folder whole to the card and launch the NEX inside it.'
$lines | Set-Content $idx -Encoding ascii
'staged: sd\LEGBLT7, index sd\LEGBLT.TXT'
