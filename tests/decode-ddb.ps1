# Decodes a message from a staged GAME.DDB exactly as the Z80 pipeline
# does.
# Usage: decode-ddb.ps1 -Kind system|user|location|object -Number N
#                      [-Leg SUITE|RAB|SFXDI|...]
# build-tests.ps1 stages into sd\<LEG>\ subfolders (see its LEG FOLDERS
# header block), never the sd\ root, so -Leg picks which staged game to
# read. Omitted, it takes the most recently written sd\*\GAME.DDB - i.e.
# whatever the last build-tests.ps1 run staged, which is what this tool
# was always pointed at back when there was only one.
param(
    [Parameter(Mandatory)][ValidateSet('system','user','location','object')][string]$Kind,
    [Parameter(Mandatory)][int]$Number,
    [string]$Leg
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
if ($Leg) {
    $ddb = Join-Path $root "sd\$Leg\GAME.DDB"
    if (-not (Test-Path -LiteralPath $ddb)) { throw "no $ddb - stage that leg first (tests\build-tests.ps1)" }
}
else {
    $ddb = Get-ChildItem "$root\sd\*\GAME.DDB" -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $ddb) { throw "no sd\*\GAME.DDB staged - run tests\build-tests.ps1 first" }
    "# reading $ddb" | Write-Host
}
$b = [IO.File]::ReadAllBytes($ddb)
$base = 0x8400
function W($o) { $b[$o] + 256 * $b[$o+1] }
$countOff = @{ system = 6; user = 5; location = 4; object = 3 }[$Kind]
$tableOff = @{ system = 0x12; user = 0x10; location = 0x0E; object = 0x0C }[$Kind]
if ($Number -ge $b[$countOff]) { throw "message $Number out of range (count $($b[$countOff]))" }
$tokPos = (W 8) - $base
$entries = @(); $p = $tokPos
while ($entries.Count -lt 129) {
    $s = ''
    while ($true) { $ch = $b[$p]; $p++; $s += [char]($ch -band 0x7F); if ($ch -band 0x80) { break } }
    $entries += $s
}
$msgPtr = (W ((W $tableOff) - $base + 2 * $Number)) - $base
$out = ''; $p = $msgPtr
while ($true) {
    $c = 255 - $b[$p]; $p++
    if ($c -eq 0x0A) { break }
    if ($c -ge 128) { $out += $entries[($c -band 0x7F) + 1]; continue }
    if ($c -eq 0x0D) { $out += "`n"; continue }
    if ($c -lt 32) { $out += ('<{0:X2}>' -f $c); continue }
    $out += [char]$c
}
$out
