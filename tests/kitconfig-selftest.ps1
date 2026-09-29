# Pins the CONFIG.BAT grammar shared by lib\kitconfig.ps1 and
# lib\vidtune\kitmodel.py: last-wins, quoted form, values holding '='.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. "$root/authoring-kit/lib/kitplatform.ps1"
. "$root/authoring-kit/lib/kitconfig.ps1"
$checks = 0
function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ("$actual" -ne "$expected") { throw "kitconfig-selftest: $what - got '$actual', expected '$expected'" }
}
$work = "$root/tests/out/kitconfig"
New-Item -ItemType Directory -Force $work | Out-Null
$cfg = @(
    '@echo off',
    'REM comment',
    'SET GAME=STARTER',
    'set toolsdir=tools',
    'SET VIDOPTS=--dither=0.3 --fps 12.5',
    'set "ARKOSDIR=C:\Program Files\Arkos Tracker 3"',
    'SET GAME=SECOND',
    'SET EMPTY=',
    '  SET   SPACED = x '
)
[IO.File]::WriteAllLines("$work/CONFIG.BAT", $cfg, [Text.Encoding]::ASCII)
[IO.File]::WriteAllLines("$work/CONFIG.local.BAT", @('SET TOOLSDIR=..\tools', 'SET RUN=0'), [Text.Encoding]::ASCII)
$c = Read-KitConfig $work
Assert-Eq $c['GAME'] 'SECOND' 'last-wins within a file'
if ($OnWindows) {
    Assert-Eq $c['TOOLSDIR'] '..\tools' 'local overrides base'
} else {
    Assert-Eq $c['TOOLSDIR'] '../tools' 'local overrides base, path key normalised'
}
Assert-Eq $c['RUN'] '0' 'local-only key present'
Assert-Eq $c['VIDOPTS'] '--dither=0.3 --fps 12.5' 'value keeps its own = signs'
if ($OnWindows) {
    Assert-Eq $c['ARKOSDIR'] 'C:\Program Files\Arkos Tracker 3' 'quoted set "NAME=value" form'
} else {
    Assert-Eq $c['ARKOSDIR'] 'C:/Program Files/Arkos Tracker 3' 'quoted set "NAME=value" form, path key normalised'
}
Assert-Eq $c.ContainsKey('EMPTY') $true 'empty value is recorded'
Assert-Eq $c['EMPTY'] '' 'empty value is blank'
Assert-Eq $c.ContainsKey('SPACED') $false 'a space before = is not a SET (cmd would name the var "SPACED ")'
Assert-Eq $c.ContainsKey('ECHO') $false '@echo off is not a setting'
$env:EMPTY = 'stale'
Export-KitConfig $c
Assert-Eq $env:GAME 'SECOND' 'exported to env'
Assert-Eq ([string]$env:EMPTY) '' 'empty value removes the env var'
Assert-Eq (Test-Path (Join-Path $work 'CONFIG.local.BAT')) $true 'fixture intact'
$none = Read-KitConfig "$work/nosuch"
Assert-Eq $none.Count 0 'missing files read as empty'
$sepWork = "$root/tests/out/kitconfig-sep"
New-Item -ItemType Directory -Force $sepWork | Out-Null
[IO.File]::WriteAllLines("$sepWork/CONFIG.BAT", @(
    'SET CSPECTDIR=C:\Emulators\CSpect',
    'SET VIDOPTS=a\b'
), [Text.Encoding]::ASCII)
$sep = Read-KitConfig $sepWork
if ($OnWindows) {
    Assert-Eq $sep['CSPECTDIR'] 'C:\Emulators\CSpect' 'path key unchanged on Windows'
} else {
    Assert-Eq $sep['CSPECTDIR'] 'C:/Emulators/CSpect' 'path key normalised on non-Windows'
}
Assert-Eq $sep['VIDOPTS'] 'a\b' 'non-path key backslash unchanged on both hosts'
Assert-Eq ($OnWindows -is [bool]) $true 'OnWindows is a bool'
Assert-Eq ($ExeSuffix -eq '.exe' -or $ExeSuffix -eq '') $true 'ExeSuffix'
$cands = @(Get-PythonCandidates)
Assert-Eq ($cands.Count -ge 2) $true 'at least two python candidates'
if ($OnWindows) {
    Assert-Eq (($cands | ForEach-Object { $_ -join ' ' }) -join ',') 'py -3,python' 'Windows python candidates'
} else {
    Assert-Eq (($cands | ForEach-Object { $_ -join ' ' }) -join ',') "python3,python,$(Join-Path $HOME 'nextdaad-venv/bin/python3')" 'Linux python candidates end with ~/nextdaad-venv'
    # Find-Python reaches the venv with no activation: a fake one under a
    # temp HOME is the only interpreter that passes the probe.
    $fakeHome = "$work/home"
    New-Item -ItemType Directory -Force "$fakeHome/nextdaad-venv/bin" | Out-Null
    $fakePy = "$fakeHome/nextdaad-venv/bin/python3"
    [IO.File]::WriteAllText($fakePy, "#!/bin/sh`nexit 0`n")
    & chmod +x $fakePy
    $oldHome = $env:HOME
    $env:HOME = $fakeHome
    try { $found = & pwsh -NoProfile -Command ". '$root/authoring-kit/lib/kitplatform.ps1'; (Find-Python @('nextdaad_selftest_no_such_module')) -join ' '" }
    finally { $env:HOME = $oldHome }
    Assert-Eq $found $fakePy 'Find-Python falls back to ~/nextdaad-venv'
}
Assert-Eq (Join-KitPath @('a', 'b', 'c.txt')) (Join-Path (Join-Path 'a' 'b') 'c.txt') 'Join-KitPath'
Write-Output "kitconfig-selftest: $checks checks passed"
