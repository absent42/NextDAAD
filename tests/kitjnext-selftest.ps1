# Pins lib\kitjnext.ps1: AUTOEXEC.BAS bytes and 8.3 card names.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$lib = "$root/authoring-kit/lib"
. "$lib/kitplatform.ps1"
. "$lib/kitjnext.ps1"
$checks = 0
function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ("$actual" -ne "$expected") { throw "kitjnext-selftest: $what - got '$actual', expected '$expected'" }
}
$hex = '50 4C 55 53 33 44 4F 53 1A 01 00 AA 00 00 00 00 2A 00 0A 00 2A 00' + (' 00' * 105) + ' 80' +
       ' 00 0A 0D 00 2E 63 64 20 2F 53 54 41 52 54 45 52 0D' +
       ' 00 14 15 00 2E 6E 65 78 6C 6F 61 64 20 53 54 41 52 54 45 52 2E 4E 45 58 0D'
$want = [byte[]]($hex.Split(' ') | ForEach-Object { [Convert]::ToByte($_, 16) })
$got = New-AutoexecBas 'STARTER' 'STARTER.NEX'
Assert-Eq $got.Length 170 'AUTOEXEC length'
Assert-Eq ([BitConverter]::ToString($got)) ([BitConverter]::ToString($want)) 'AUTOEXEC bytes = spike file'
$sum = 0
foreach ($b in $got[0..126]) { $sum += $b }
Assert-Eq ($sum % 256) $got[127] 'AUTOEXEC header checksum'
Assert-Eq (Get-JNextCardName 'STARTER') 'STARTER' 'clean name kept'
Assert-Eq (Get-JNextCardName 'rollercoaster') 'ROLLERCO' 'long name truncated'
Assert-Eq (Get-JNextCardName 'My Game') 'MYXGAME' 'space replaced'
Assert-Eq (Get-JNextCardName '') 'GAME' 'empty name'
Assert-Eq (Get-JNextLaunchNex 'STARTER.NEX') 'STARTER.NEX' '8.3 NEX launched by name'
Assert-Eq (Get-JNextLaunchNex 'Starter.nex') 'STARTER.NEX' 'case folded'
Assert-Eq (Get-JNextLaunchNex 'ROLLERCOASTER.NEX') 'RUN.NEX' 'long NEX uses RUN.NEX'
Write-Output "kitjnext-selftest: $checks checks passed"
