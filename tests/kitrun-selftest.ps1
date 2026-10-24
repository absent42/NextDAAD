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
    [IO.File]::WriteAllText($fake, "@echo %*>>`"%FAKE_JNEXT_LOG%`"`r`n@exit /b %FAKE_JNEXT_RC%`r`n")
} else {
    $fake = Join-Path $base 'fakejnext'
    [IO.File]::WriteAllText($fake, "#!/bin/sh`necho `"`$*`" >> `"`$FAKE_JNEXT_LOG`"`nexit `$FAKE_JNEXT_RC`n")
    & chmod +x $fake
}
$hostExe = (Get-Process -Id $PID).Path

function Invoke-Kit([string]$Script, [string[]]$Local) {
    [IO.File]::WriteAllLines("$kit/CONFIG.local.BAT", $Local, [Text.Encoding]::ASCII)
    Push-Location $kit
    try {
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $out = & $hostExe -NoProfile -ExecutionPolicy Bypass -File "lib/$Script" 2>&1 | ForEach-Object { "$_" }
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $eap
    } finally { Pop-Location }
    return @{ Rc = $rc; Out = ($out -join "`n") }
}
function Reset-Log { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }

$r = Invoke-Kit 'run.ps1' @('SET EMULATOR=mame')
Assert-Eq $r.Rc 1 'bad value exit'
Assert-Like $r.Out '*EMULATOR=mame - use cspect or jnext*' 'bad value text'

$r = Invoke-Kit 'run.ps1' @('SET EMULATOR=jnext', 'SET JNEXTDIR=nosuch')
Assert-Eq $r.Rc 1 'no jNext exit'
Assert-Like $r.Out '*ERROR: jNext not found at*' 'no jNext text'
Assert-Like $r.Out '*Install jNext 1.1.87 or later there, or set JNEXTDIR in CONFIG.BAT.*' 'no jNext hint'

$r = Invoke-Kit 'run.ps1' @('SET EMULATOR=jnext', "SET JNEXT=$fake", 'SET JNEXTIMG=nosuch.img')
Assert-Eq $r.Rc 1 'no image exit'
Assert-Like $r.Out '*ERROR: no jNext SD-card image at*' 'no image text'
Assert-Like $r.Out '*set JNEXTIMG in CONFIG.BAT.*' 'no image hint'

$happy = @('SET EMULATOR=JNext', "SET JNEXT=$fake", "SET JNEXTIMG=$baseImg")
if ($OnWindows -and @(Get-Process -Name jnext -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Output 'skip: happy path, failed add (a jnext process is running)'
} else {
    Reset-Log
    $r = Invoke-Kit 'run.ps1' $happy
    Assert-Eq $r.Rc 0 'happy path exit'
    $lines = @(Get-Content -LiteralPath $log)
    $sep = [IO.Path]::DirectorySeparatorChar
    Assert-Eq $lines.Count 3 'happy path call count'
    Assert-Like $lines[0] '*--sdcard-file-dest /NEXTZXOS/AUTOEXEC.BAS*' 'call 1 AUTOEXEC'
    Assert-Like $lines[1] '*--sdcard-file-dest /G1' 'call 2 game folder'
    $relG1 = "$kit${sep}RELEASE${sep}G1"
    Assert-Like $lines[1] "*--sdcard-file-add*$relG1*--sdcard-file-dest*" 'call 2 adds the built game folder by its real path'
    $cardPath = "$kit${sep}CACHE${sep}jnext${sep}card.img"
    Assert-Like $lines[2] "*--sdcard *$cardPath*" 'boot line holds the card path with its space'
    Assert-Like $lines[2] '*kit dir*' 'boot line keeps the space'
    Assert-Eq (Test-Path -LiteralPath $cardPath) $true 'card image exists'

    $c = Invoke-Kit 'clean.ps1' $happy
    Assert-Eq $c.Rc 0 'clean exit'
    Assert-Like $c.Out "*removed CACHE${sep}jnext${sep}card.img*" 'clean prints the card removal'
    Assert-Eq (Test-Path -LiteralPath $cardPath) $false 'card removed by clean'
    Assert-Eq (Test-Path -LiteralPath "$kit/RELEASE/G1") $false 'RELEASE game removed by clean'
    New-Item -ItemType Directory -Path "$kit/RELEASE/G1/DATA" -Force | Out-Null
    [IO.File]::WriteAllBytes("$kit/RELEASE/G1/G1.NEX", [byte[]](1..4))

    Reset-Log
    $env:FAKE_JNEXT_RC = '1'
    $r = Invoke-Kit 'run.ps1' $happy
    $env:FAKE_JNEXT_RC = '0'
    Assert-Eq $r.Rc 1 'failed add exit'
    Assert-Like $r.Out '*step 1, exit 1*' 'failed add text'
    Assert-Eq @(Get-Content -LiteralPath $log).Count 1 'failed add stops after one call'
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

Remove-Item Env:FAKE_JNEXT_RC, Env:FAKE_JNEXT_LOG
Remove-Item -LiteralPath $base -Recurse -Force
Write-Output "kitrun-selftest: $checks checks passed"
