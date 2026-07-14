# Decodes a message from sd\GAME.DDB exactly as the Z80 pipeline does.
# Usage: decode-ddb.ps1 -Kind system|user|location|object -Number N
param(
    [Parameter(Mandatory)][ValidateSet('system','user','location','object')][string]$Kind,
    [Parameter(Mandatory)][int]$Number
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$b = [IO.File]::ReadAllBytes("$root\sd\GAME.DDB")
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
