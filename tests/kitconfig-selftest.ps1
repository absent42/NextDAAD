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
[IO.File]::WriteAllLines("$work\CONFIG.local.BAT", @('SET TOOLSDIR=..\tools', 'SET RUN=0'), [Text.Encoding]::ASCII)
$c = Read-KitConfig $work
Assert-Eq $c['GAME'] 'SECOND' 'last-wins within a file'
Assert-Eq $c['TOOLSDIR'] '..\tools' 'local overrides base'
Assert-Eq $c['RUN'] '0' 'local-only key present'
Assert-Eq $c['VIDOPTS'] '--dither=0.3 --fps 12.5' 'value keeps its own = signs'
Assert-Eq $c['ARKOSDIR'] 'C:\Program Files\Arkos Tracker 3' 'quoted set "NAME=value" form'
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
Assert-Eq ($OnWindows -is [bool]) $true 'OnWindows is a bool'
Assert-Eq ($ExeSuffix -eq '.exe' -or $ExeSuffix -eq '') $true 'ExeSuffix'
$cands = @(Get-PythonCandidates)
Assert-Eq ($cands.Count -ge 2) $true 'at least two python candidates'
Assert-Eq (Join-KitPath @('a', 'b', 'c.txt')) (Join-Path (Join-Path 'a' 'b') 'c.txt') 'Join-KitPath'
Write-Output "kitconfig-selftest: $checks checks passed"
