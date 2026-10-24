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

# Publish-JNextCard against a fake jnext that logs its arguments.
$work = Join-Path $root 'tests/out/kitjnext-fake'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path "$work/G1/DATA" -Force | Out-Null
[IO.File]::WriteAllBytes("$work/G1/ROLLERCOASTER.NEX", [byte[]](1..16))
[IO.File]::WriteAllBytes("$work/G1/DATA/GAME.DDB", [byte[]](1..16))
[IO.File]::WriteAllBytes("$work/base.img", (New-Object byte[] 4096))
$base = "$work/base.img"
$env:FAKE_JNEXT_LOG = "$work/fake.log"
if ($OnWindows) {
    $fake = "$work/fakejnext.cmd"
    [IO.File]::WriteAllText($fake, "@echo %*>>`"%FAKE_JNEXT_LOG%`"`r`n@exit /b %FAKE_JNEXT_RC%`r`n")
} else {
    $fake = "$work/fakejnext"
    [IO.File]::WriteAllText($fake, "#!/bin/sh`necho `"`$*`" >> `"`$FAKE_JNEXT_LOG`"`nexit `$FAKE_JNEXT_RC`n")
    & chmod +x $fake
}
$env:FAKE_JNEXT_RC = '0'
$dir = Publish-JNextCard $fake $base "$work/CACHE/jnext/card.img" "$work/G1" 'ROLLERCOASTER.NEX' $work
Assert-Eq $dir 'ROLLERCO' 'card folder name returned'
$log = @(Get-Content $env:FAKE_JNEXT_LOG)
Assert-Eq $log.Count 3 'three adds for a long NEX name'
Assert-Eq ($log[0] -like '*--sdcard-file-dest /NEXTZXOS/AUTOEXEC.BAS --sdcard-file-force*') $true 'AUTOEXEC add first'
Assert-Eq ($log[1] -like '*--sdcard-file-dest /ROLLERCO') $true 'game folder add'
Assert-Eq ($log[2] -like '*--sdcard-file-dest /ROLLERCO/RUN.NEX') $true 'RUN.NEX copy'
Assert-Eq (Test-Path "$work/CACHE/jnext/card.img") $true 'card copied from base'
Assert-Eq (Test-Path "$work/AUTOEXEC.BAS") $true 'AUTOEXEC.BAS written to work dir'
Remove-Item $env:FAKE_JNEXT_LOG
Copy-Item "$work/G1/ROLLERCOASTER.NEX" "$work/G1/G1.NEX"
$dir = Publish-JNextCard $fake $base "$work/c1.img" "$work/G1" 'G1.NEX' $work
Assert-Eq $dir 'G1' 'short game name'
Assert-Eq @(Get-Content $env:FAKE_JNEXT_LOG).Count 2 'two adds for an 8.3 NEX name'
$env:FAKE_JNEXT_RC = '1'; Remove-Item $env:FAKE_JNEXT_LOG
$msg = $null; try { Publish-JNextCard $fake $base "$work/c2.img" "$work/G1" 'G1.NEX' $work } catch { $msg = $_.Exception.Message }
Assert-Eq ($msg -like '*step 1, exit 1*') $true 'failed add stops the run'
Assert-Eq @(Get-Content $env:FAKE_JNEXT_LOG).Count 1 'nothing after the failed add'
Assert-Eq ($null -ne (Test-JNextRunning)) $true 'Test-JNextRunning returns a bool'
Remove-Item Env:FAKE_JNEXT_RC, Env:FAKE_JNEXT_LOG
Remove-Item $work -Recurse -Force

# Real jNext (file-copy mode only; never emulates): stage STARTER, check the card.
$jexe = if ($env:JNEXT_SELFTEST_EXE) { $env:JNEXT_SELFTEST_EXE } else { ('D:/ZXNextDev/jnext/jnext' + $ExeSuffix) }
$jbase = Join-Path $HOME '.jnext/sdcard/cspect-next-1gb-fixed.img'
$starter = Join-Path $root 'authoring-kit/RELEASE/STARTER'
$py = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not ((Test-Path $jexe) -and (Test-Path $jbase) -and (Test-Path "$starter/STARTER.NEX") -and $py)) {
    Write-Output 'skip: real jNext integration (jnext, base image, built STARTER or python missing)'
} else {
    $out = Join-Path $root 'tests/out/kitjnext'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $card = "$out/card.img"
    try {
        $d = Publish-JNextCard $jexe $jbase $card $starter 'STARTER.NEX' $out
        Assert-Eq $d 'STARTER' 'integration card folder'
        $chk = & $py.Source -I (Join-Path $root 'tests/jnext_cardcheck.py') $card $d $starter 2>&1
        $chk | Out-Host
        Assert-Eq $LASTEXITCODE 0 'jnext_cardcheck exits 0 on the staged card'
        $tmp = Join-Path $out 'AUTOEXEC.READ'
        & $py.Source -I (Join-Path $root 'tests/jnext_cardcheck.py') --extract $card /NEXTZXOS/AUTOEXEC.BAS $tmp 2>&1 | Out-Host
        Assert-Eq ([BitConverter]::ToString([IO.File]::ReadAllBytes($tmp))) ([BitConverter]::ToString($want)) 'read-back AUTOEXEC = vector'
    } finally {
        Remove-Item $card -Force -ErrorAction SilentlyContinue
    }
}
Write-Output "kitjnext-selftest: $checks checks passed"
