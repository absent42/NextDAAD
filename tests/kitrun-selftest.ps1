# Pins lib\run.ps1 emulator selection and lib\clean.ps1 card removal in a scratch kit.
# Never starts an emulator: jNext is a fake that logs its arguments, CSpect is absent.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. "$root/authoring-kit/lib/kitplatform.ps1"
$checks = 0
function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ("$actual" -ne "$expected") { throw "kitrun-selftest: $what - got '$actual', expected '$expected'" }
}
function Assert-Like($actual, $pattern, $what) {
    $script:checks++
    if ("$actual" -notlike $pattern) { throw "kitrun-selftest: $what - '$actual' not like '$pattern'" }
}

$base = Join-Path $root 'tests/out/kitrun'
$kit = Join-Path $base 'kit dir'
if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
New-Item -ItemType Directory -Path "$kit/lib", "$kit/G1", "$kit/RELEASE/G1/DATA" -Force | Out-Null
foreach ($f in Get-ChildItem "$root/authoring-kit/lib/*.ps1") { Copy-Item -LiteralPath $f.FullName -Destination "$kit/lib/" }
Copy-Item "$root/authoring-kit/lib/toolversions.txt" "$kit/lib/"
[IO.File]::WriteAllLines("$kit/CONFIG.BAT", @('@echo off', 'SET GAME=G1', 'SET RUN=0'), [Text.Encoding]::ASCII)
[IO.File]::WriteAllText("$kit/G1/G1.DSF", '')
[IO.File]::WriteAllBytes("$kit/RELEASE/G1/G1.NEX", [byte[]](1..4))
[IO.File]::WriteAllBytes("$kit/RELEASE/G1/DATA/GAME.DDB", [byte[]](1..4))
$baseImg = Join-Path $base 'base.img'
[IO.File]::WriteAllBytes($baseImg, (New-Object byte[] 4096))
$log = Join-Path $base 'fake.log'
$env:FAKE_JNEXT_LOG = $log
$env:FAKE_JNEXT_RC = '0'
if ($OnWindows) {
    $fake = Join-Path $base 'fakejnext.cmd'
    [IO.File]::WriteAllText($fake, "@echo --- call>>`"%FAKE_JNEXT_LOG%`"`r`n:l`r`n@if `"%~1`"==`"`" goto e`r`n@echo [%~1]>>`"%FAKE_JNEXT_LOG%`"`r`n@shift`r`n@goto l`r`n:e`r`n@exit /b %FAKE_JNEXT_RC%`r`n")
} else {
    $fake = Join-Path $base 'fakejnext'
    [IO.File]::WriteAllText($fake, "#!/bin/sh`necho '--- call' >> `"`$FAKE_JNEXT_LOG`"`nfor a in `"`$@`"; do echo `"[`$a]`" >> `"`$FAKE_JNEXT_LOG`"; done`nexit `$FAKE_JNEXT_RC`n")
    & chmod +x $fake
}
$hostExe = (Get-Process -Id $PID).Path

function Invoke-Kit([string]$Script, [string[]]$Local) {
    [IO.File]::WriteAllLines("$kit/CONFIG.local.BAT", $Local, [Text.Encoding]::ASCII)
    Push-Location $kit
    $eap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $hostExe -NoProfile -ExecutionPolicy Bypass -File "lib/$Script" 2>&1 | ForEach-Object { "$_" }
        $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $eap; Pop-Location }
    return @{ Rc = $rc; Out = ($out -join "`n") }
}
# One fake-jnext call per element: the bracketed argument lines after each "--- call" marker.
function Get-Calls {
    $calls = @(); $cur = $null
    foreach ($l in @(Get-Content -LiteralPath $log)) {
        if ($l -eq '--- call') { if ($null -ne $cur) { $calls += , $cur }; $cur = @() } else { $cur += $l }
    }
    if ($null -ne $cur) { $calls += , $cur }
    return , $calls
}
function Reset-Log { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }

$r = Invoke-Kit 'run.ps1' @('SET EMULATOR=mame')
Assert-Eq $r.Rc 1 'bad value exit'
Assert-Like $r.Out '*EMULATOR=mame - use cspect or jnext*' 'bad value text'

$r = Invoke-Kit 'run.ps1' @('SET EMULATOR=jnext', 'SET JNEXTDIR=nosuch')
Assert-Eq $r.Rc 1 'no jNext exit'
Assert-Like $r.Out '*ERROR: jNext not found at*' 'no jNext text'
Assert-Like $r.Out '*Install jNext 1.1.87 or later there, or set JNEXTDIR in CONFIG.local.BAT.*' 'no jNext hint'

$r = Invoke-Kit 'run.ps1' @('SET EMULATOR=jnext', "SET JNEXT=$fake", 'SET JNEXTIMG=nosuch.img')
Assert-Eq $r.Rc 1 'no image exit'
Assert-Like $r.Out '*ERROR: no jNext SD-card image at*' 'no image text'
Assert-Like $r.Out '*set JNEXTIMG in CONFIG.local.BAT.*' 'no image hint'

$happy = @('SET EMULATOR=JNext', "SET JNEXT=$fake", "SET JNEXTIMG=$baseImg")
if ($OnWindows -and @(Get-Process -Name jnext -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Output 'skip: happy path, failed add (a jnext process is running)'
} else {
    Reset-Log
    $r = Invoke-Kit 'run.ps1' $happy
    Assert-Eq $r.Rc 0 'happy path exit'
    $calls = Get-Calls
    $sep = [IO.Path]::DirectorySeparatorChar
    $cardPath = "$kit${sep}CACHE${sep}jnext${sep}card.img"
    $relG1 = "$kit${sep}RELEASE${sep}G1"
    Assert-Eq $calls.Count 3 'happy path call count'
    Assert-Eq ($calls[0] -contains '[/NEXTZXOS/AUTOEXEC.BAS]') $true 'call 1 AUTOEXEC'
    Assert-Eq ($calls[1] -contains '[/G1]') $true 'call 2 game folder'
    Assert-Eq ($calls[1] -contains "[$relG1]") $true 'call 2 adds the built game folder, whole path with its space'
    foreach ($i in 0..2) { Assert-Eq ($calls[$i] -contains "[$cardPath]") $true "call $($i + 1) card path is one argument with its space" }
    Assert-Eq $calls[2].Count 2 'boot call is --sdcard and the card'
    Assert-Eq $calls[2][1] "[$cardPath]" 'boot call card argument'
    Assert-Eq (Test-Path -LiteralPath $cardPath) $true 'card image exists'

    $c = Invoke-Kit 'clean.ps1' $happy
    Assert-Eq $c.Rc 0 'clean exit'
    Assert-Like $c.Out "*removed CACHE${sep}jnext${sep}*" 'clean prints the jnext folder removal'
    Assert-Eq (Test-Path -LiteralPath $cardPath) $false 'card removed by clean'
    Assert-Eq (Test-Path -LiteralPath "$kit/CACHE/jnext") $false 'CACHE/jnext folder removed by clean (AUTOEXEC.BAS too)'
    Assert-Eq ($c.Out -like '*nothing to clean*') $false 'clean with something removed does not say nothing to clean'
    Assert-Eq (Test-Path -LiteralPath "$kit/RELEASE/G1") $false 'RELEASE game removed by clean'
    New-Item -ItemType Directory -Path "$kit/RELEASE/G1/DATA" -Force | Out-Null
    [IO.File]::WriteAllBytes("$kit/RELEASE/G1/G1.NEX", [byte[]](1..4))

    Reset-Log
    $env:FAKE_JNEXT_RC = '1'
    $r = Invoke-Kit 'run.ps1' $happy
    $env:FAKE_JNEXT_RC = '0'
    Assert-Eq $r.Rc 1 'failed add exit'
    Assert-Like $r.Out '*step 1, exit 1*' 'failed add text'
    Assert-Eq (Get-Calls).Count 1 'failed add stops after one call'

    Remove-Item -LiteralPath "$kit/RELEASE/G1" -Recurse -Force
    Assert-Eq (Test-Path -LiteralPath "$kit/CACHE/jnext") $true 'failed run left the jnext folder'
    $c = Invoke-Kit 'clean.ps1' $happy
    Assert-Like $c.Out "*removed CACHE${sep}jnext${sep}*" 'clean with only the card present removes it'
    Assert-Eq ($c.Out -like '*nothing to clean*') $false 'no contradictory nothing-to-clean line'
    $c = Invoke-Kit 'clean.ps1' $happy
    Assert-Like $c.Out '*nothing to clean*' 'clean with neither present says nothing to clean'
    Assert-Eq ($c.Out -like '*removed*') $false 'nothing to clean prints no removal'
    New-Item -ItemType Directory -Path "$kit/RELEASE/G1/DATA" -Force | Out-Null
    [IO.File]::WriteAllBytes("$kit/RELEASE/G1/G1.NEX", [byte[]](1..4))
}

if ($OnWindows) {
    Write-Output 'skip: running-jNext case (Linux only; Windows is covered by the hardware leg)'
} else {
    $dummy = Join-Path $base 'dummy/jnext'
    New-Item -ItemType Directory -Path (Split-Path $dummy) -Force | Out-Null
    Copy-Item /bin/sleep $dummy
    $p = Start-Process -FilePath $dummy -ArgumentList '30' -PassThru
    try {
        Start-Sleep -Milliseconds 300
        Reset-Log
        $r = Invoke-Kit 'run.ps1' $happy
        Assert-Eq $r.Rc 1 'running exit'
        Assert-Like $r.Out '*ERROR: jNext is running*' 'running text'
        Assert-Eq (Test-Path -LiteralPath $log) $false 'running case calls nothing'
    } finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}

$r = Invoke-Kit 'run.ps1' @('SET EMULATOR=', 'SET CSPECTDIR=nosuch')
Assert-Eq $r.Rc 1 'cspect unchanged exit'
Assert-Like $r.Out '*ERROR: CSpect not found at*' 'cspect unchanged text'

# CSpect launch: a stand-in CSpect.exe logs one argument per line. On Linux the card root
# ends in two separators: CSpect's esxDOS plugin trims one and needs one left to enter DATA.
$csd = Join-Path $base 'fakecs'
. "$root/authoring-kit/lib/kittools.ps1"
# The file name the kit looks for in CSPECTDIR; Resolve-KitTools sets env as a side effect.
$envSaved = @{}; foreach ($k in 'TOOLSDIR', 'FFMPEG', 'VIDENC') { $envSaved[$k] = [Environment]::GetEnvironmentVariable($k) }
$csExe = Join-Path $csd (Split-Path -Leaf (Resolve-KitTools @{} $kit).CSPECT)
foreach ($k in $envSaved.Keys) { [Environment]::SetEnvironmentVariable($k, $envSaved[$k]) }
New-Item -ItemType Directory -Path $csd -Force | Out-Null
$csLog = Join-Path $base 'cspect.log'
$env:FAKE_CSPECT_LOG = $csLog
$csLocal = @('SET EMULATOR=cspect', "SET CSPECTDIR=$csd")
$haveFake = $true
if ($OnWindows) {
    try { Add-Type -TypeDefinition 'public static class FakeCSpect { public static void Main(string[] a) { System.IO.File.WriteAllLines(System.Environment.GetEnvironmentVariable("FAKE_CSPECT_LOG"), a); } }' -OutputAssembly $csExe -OutputType ConsoleApplication }
    catch { $haveFake = $false }
} else {
    [IO.File]::WriteAllText($csExe, "for a in `"`$@`"; do echo `"`$a`"; done > `"`$FAKE_CSPECT_LOG`"`n")
    $csLocal += 'SET CSPECTCMD=sh'
}
if (-not $haveFake) { Write-Output 'skip: cspect launch line (this host cannot compile a console stand-in)' }
else {
    $r = Invoke-Kit 'run.ps1' $csLocal
    Assert-Eq $r.Rc 0 'cspect launch exit'
    $a = @(Get-Content -LiteralPath $csLog)
    $s = [IO.Path]::DirectorySeparatorChar
    $mmcWant = if ($OnWindows) { "-mmc=RELEASE${s}G1${s}" } else { "-mmc=RELEASE${s}G1${s}${s}" }
    Assert-Eq ($a -join '|') "-w3|-zxnext|-esc|$mmcWant|RELEASE${s}G1${s}G1.NEX" 'cspect launch arguments'
}
Remove-Item Env:FAKE_CSPECT_LOG

Remove-Item Env:FAKE_JNEXT_RC, Env:FAKE_JNEXT_LOG
Remove-Item -LiteralPath $base -Recurse -Force
Write-Output "kitrun-selftest: $checks checks passed"
