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
Assert-Eq (Get-JNextCardName 'ABCDEFGH') 'ABCDEFGH' 'exactly 8 chars kept'
Assert-Eq (Get-JNextCardName '!!!') 'XXX' 'all-invalid name becomes X'
Assert-Eq (Get-JNextLaunchNex 'STARTER.NEX') 'STARTER.NEX' '8.3 NEX launched by name'
Assert-Eq (Get-JNextLaunchNex 'Starter.nex') 'STARTER.NEX' 'case folded'
Assert-Eq (Get-JNextLaunchNex 'ROLLERCOASTER.NEX') 'RUN.NEX' 'long NEX uses RUN.NEX'
Assert-Eq (Get-JNextLaunchNex 'ABCDEFGHI.NEX') 'RUN.NEX' '9-char NEX stem uses RUN.NEX'

# Publish-JNextCard against a fake jnext that logs its arguments.
$work = Join-Path $root 'tests/out/kitjnext fake'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path "$work/G1/DATA" -Force | Out-Null
[IO.File]::WriteAllBytes("$work/G1/ROLLERCOASTER.NEX", [byte[]](1..16))
[IO.File]::WriteAllBytes("$work/G1/DATA/GAME.DDB", [byte[]](1..16))
[IO.File]::WriteAllBytes("$work/base.img", (New-Object byte[] 4096))
$base = "$work/base.img"
$env:FAKE_JNEXT_LOG = "$work/fake.log"
if ($OnWindows) {
    $fake = "$work/fakejnext.cmd"
    [IO.File]::WriteAllText($fake, "@echo --- call>>`"%FAKE_JNEXT_LOG%`"`r`n:l`r`n@if `"%~1`"==`"`" goto e`r`n@echo [%~1]>>`"%FAKE_JNEXT_LOG%`"`r`n@shift`r`n@goto l`r`n:e`r`n@exit /b %FAKE_JNEXT_RC%`r`n")
} else {
    $fake = "$work/fakejnext"
    [IO.File]::WriteAllText($fake, "#!/bin/sh`necho '--- call' >> `"`$FAKE_JNEXT_LOG`"`nfor a in `"`$@`"; do echo `"[`$a]`" >> `"`$FAKE_JNEXT_LOG`"; done`nexit `$FAKE_JNEXT_RC`n")
    & chmod +x $fake
}
$env:FAKE_JNEXT_RC = '0'
$dir = Publish-JNextCard $fake $base "$work/CACHE/jnext/card.img" "$work/G1" 'ROLLERCOASTER.NEX' $work
Assert-Eq $dir 'ROLLERCO' 'card folder name returned'
function Get-Calls {
    $calls = @(); $cur = $null
    foreach ($l in @(Get-Content -LiteralPath $env:FAKE_JNEXT_LOG)) {
        if ($l -eq '--- call') { if ($null -ne $cur) { $calls += , $cur }; $cur = @() } else { $cur += $l }
    }
    if ($null -ne $cur) { $calls += , $cur }
    return , $calls
}
$cardPath = "$work/CACHE/jnext/card.img"
$calls = Get-Calls
Assert-Eq $calls.Count 3 'three adds for a long NEX name'
Assert-Eq ($calls[0] -contains '[/NEXTZXOS/AUTOEXEC.BAS]') $true 'AUTOEXEC add first'
Assert-Eq ($calls[0] -contains '[--sdcard-file-force]') $true 'AUTOEXEC add is forced'
Assert-Eq ($calls[1] -contains '[/ROLLERCO]') $true 'game folder add'
Assert-Eq ($calls[2] -contains '[/ROLLERCO/RUN.NEX]') $true 'RUN.NEX copy'
foreach ($i in 0..2) { Assert-Eq ($calls[$i] -contains "[$cardPath]") $true "call $($i + 1) card path is one argument with its space" }
Assert-Eq ($calls[0] -contains "[$(Join-Path $work 'AUTOEXEC.BAS')]") $true 'AUTOEXEC source is one argument with its space'
Assert-Eq ($calls[1] -contains "[$work/G1]") $true 'game folder source is one argument with its space'
Assert-Eq ($calls[2] -contains "[$(Join-Path "$work/G1" 'ROLLERCOASTER.NEX')]") $true 'NEX source is one argument with its space'
Assert-Eq (Test-Path "$work/CACHE/jnext/card.img") $true 'card copied from base'
Assert-Eq (Test-Path "$work/AUTOEXEC.BAS") $true 'AUTOEXEC.BAS written to work dir'
Remove-Item $env:FAKE_JNEXT_LOG
Copy-Item "$work/G1/ROLLERCOASTER.NEX" "$work/G1/G1.NEX"
$dir = Publish-JNextCard $fake $base "$work/c1.img" "$work/G1" 'G1.NEX' $work
Assert-Eq $dir 'G1' 'short game name'
Assert-Eq (Get-Calls).Count 2 'two adds for an 8.3 NEX name'
$env:FAKE_JNEXT_RC = '1'; Remove-Item $env:FAKE_JNEXT_LOG
$msg = $null; try { Publish-JNextCard $fake $base "$work/c2.img" "$work/G1" 'G1.NEX' $work } catch { $msg = $_.Exception.Message }
Assert-Eq ($msg -like '*step 1, exit 1*') $true 'failed add stops the run'
Assert-Eq (Get-Calls).Count 1 'nothing after the failed add'
$running = Test-JNextRunning
Assert-Eq ($running -is [bool]) $true 'Test-JNextRunning returns a bool'
if ($OnWindows) {
    if (@(Get-Process -Name jnext -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Output 'skip: Test-JNextRunning false-case (a jnext process is running)'
    } else {
        Assert-Eq $running $false 'Test-JNextRunning false with no jnext process'
    }
}
Remove-Item Env:FAKE_JNEXT_RC, Env:FAKE_JNEXT_LOG
Remove-Item $work -Recurse -Force

# jnext_cardcheck.compare against a fake card: RUN.NEX accepted for a long NEX, MISSING reported.
$py0 = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($py0) {
    $unit = @'
import importlib.util, os, sys, tempfile
spec = importlib.util.spec_from_file_location("cc", sys.argv[1]); cc = importlib.util.module_from_spec(spec); spec.loader.exec_module(cc)
class FS:
    def __init__(s, files): s.files = files
    def read_dir(s, c): return [(n, False, i + 1, len(d)) for i, (n, d) in enumerate(s.files)]
    def chain(s, c): return [c]
    def read_chain(s, c, size=None): d = s.files[c - 1][1]; return d if size is None else d[:size]
    def lookup(s, p): return 0
def run(card, src):
    d = tempfile.mkdtemp()
    for n, b in src: open(os.path.join(d, n), "wb").write(b)
    cc.Fat32 = FS
    return cc.compare(FS(card), "X", d)
nex = b"nexdata"
print("RESULT", run([("RUN.NEX", nex), ("A.DAT", b"a")], [("ROLLERCOASTER.NEX", nex), ("A.DAT", b"a")]),
      run([("A.DAT", b"a")], [("ROLLERCOASTER.NEX", nex), ("A.DAT", b"a")]),
      run([("RUN.NEX", nex), ("A.DAT", b"a")], [("A.DAT", b"a")]))
'@
    $unitFile = Join-Path $root 'tests/out/cardcheck_unit.py'
    New-Item -ItemType Directory -Path (Split-Path $unitFile) -Force | Out-Null
    [IO.File]::WriteAllText($unitFile, $unit)
    try { $ur = & $py0.Source -I $unitFile (Join-Path $root 'tests/jnext_cardcheck.py') 2>&1 } finally { Remove-Item $unitFile -Force -ErrorAction SilentlyContinue }
    $ur | Out-Host
    Assert-Eq (($ur | Where-Object { "$_" -like 'RESULT*' }) -join '') 'RESULT 0 1 1' 'cardcheck: long-NEX RUN.NEX ok, missing file and extra file reported'
}

# Real jNext (file-copy mode only; never emulates): stage STARTER, check the card.
$jexe = if ($env:JNEXT_SELFTEST_EXE) { $env:JNEXT_SELFTEST_EXE } else { ('D:/ZXNextDev/jnext/jnext' + $ExeSuffix) }
$jbase = Join-Path $HOME '.jnext/sdcard/cspect-next-1gb-fixed.img'
$starter = if ($env:JNEXT_SELFTEST_STARTER) { $env:JNEXT_SELFTEST_STARTER } else { Join-Path $root 'authoring-kit/RELEASE/STARTER' }
$py = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$toolsRepo = Join-Path $root 'tools'
$kitWork = Join-Path $root 'tests/out/kitjnext-kit'
$skip = $null
if (-not ((Test-Path $jexe) -and (Test-Path $jbase) -and $py)) { $skip = 'jnext, base image or python missing' }
elseif (-not (Test-Path "$starter/STARTER.NEX")) {
    # Build STARTER in a scratch copy of the tracked kit: RUN=0 so no emulator can start.
    if (-not (Test-Path $toolsRepo -PathType Container)) { $skip = 'STARTER not built and the toolchain folder is missing' }
    else {
        if (Test-Path $kitWork) { Remove-Item $kitWork -Recurse -Force }
        $kitSrc = Join-Path $root 'authoring-kit'
        foreach ($rel in (& git -C $kitSrc ls-files)) {
            $dst = Join-Path $kitWork $rel
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
            [IO.File]::Copy((Join-Path $kitSrc $rel), $dst, $true)
        }
        $local = @('@echo off', "SET TOOLSDIR=$toolsRepo", "SET FFMPEGDIR=$(Join-Path $kitSrc 'tools/ffmpeg')",
                   "SET GFXDIR=$(Join-Path $kitWork 'tools/gfx2next')", "SET VIDTOOLSDIR=$(Join-Path $kitWork 'tools/vidtools')",
                   'SET RUN=0', 'SET GAME=STARTER')
        [IO.File]::WriteAllLines((Join-Path $kitWork 'CONFIG.local.BAT'), $local, [Text.Encoding]::ASCII)
        $hostExe = (Get-Process -Id $PID).Path
        Push-Location $kitWork
        $eap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kitWork 'lib/build.ps1') 2>&1 | ForEach-Object { "$_" } | Out-Host
            $brc = $LASTEXITCODE
        } finally { $ErrorActionPreference = $eap; Pop-Location }
        Assert-Eq $brc 0 'scratch STARTER build exit'
        $starter = Join-Path $kitWork 'RELEASE/STARTER'
        Assert-Eq (Test-Path "$starter/STARTER.NEX") $true 'scratch build produced STARTER.NEX'
    }
}
if ($skip) {
    Write-Output "skip: real jNext integration ($skip)"
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
        if (Test-Path $kitWork) { Remove-Item $kitWork -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
Write-Output "kitjnext-selftest: $checks checks passed"
