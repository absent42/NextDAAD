# Each case breaks a fresh fixture kit one way and asserts BUILD refuses
# with exit 1 and the expected message. Messages are the v0.11.0 wording.
param([string]$ToolsDir = '', [string]$FfmpegDir = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or ($IsWindows -eq $true)
$sep = [IO.Path]::DirectorySeparatorChar
$buildName = if ($onWindows) { 'BUILD.BAT' } else { 'build.sh' }
$kit = Join-Path $root 'tests/out/kit parity/kit'
$cases = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'negative/cases.txt') -Encoding ASCII | Where-Object { $_ -and -not $_.StartsWith('#') }
$failed = 0

function Prepare {
    # Hashtable splat: an array splat of dash-prefixed strings binds
    # positionally, not by name, so -PrepareOnly would land in $ToolsDir.
    $prepArgs = @{ PrepareOnly = $true }
    if ($ToolsDir) { $prepArgs.ToolsDir = $ToolsDir }
    if ($FfmpegDir) { $prepArgs.FfmpegDir = $FfmpegDir }
    & (Join-Path $PSScriptRoot 'parity.ps1') @prepArgs | Out-Null
    if ($LASTEXITCODE -eq 2) { Write-Host 'negative: tools missing'; exit 2 }
    if ($LASTEXITCODE -ne 0) { throw 'parity -PrepareOnly failed' }
}
function Set-Config([string]$name, [string]$value) {
    Add-Content -LiteralPath (Join-Path $kit 'CONFIG.local.BAT') -Value "SET $name=$value" -Encoding ASCII
}
function Apply-Setup([string]$setup) {
    foreach ($step in $setup.Split(';')) {
        $s = $step.Trim()
        if ($s -match '^remove (.+)$') { Remove-Item -LiteralPath (Join-Path $kit $Matches[1]) -Force -Recurse }
        elseif ($s -match '^copy (\S+) (\S+)$') { Copy-Item -LiteralPath (Join-Path $kit $Matches[1]) -Destination (Join-Path $kit $Matches[2]) }
        elseif ($s -match '^rename (\S+) (\S+)$') {
            # A case-only rename is refused by some hosts; a temporary
            # name in between always succeeds.
            $src = Join-Path $kit $Matches[1]
            try { Rename-Item -LiteralPath $src -NewName $Matches[2] }
            catch {
                $tmp = "$($Matches[2]).renametmp"
                Rename-Item -LiteralPath $src -NewName $tmp
                Rename-Item -LiteralPath (Join-Path (Split-Path $src) $tmp) -NewName $Matches[2]
            }
        }
        elseif ($s -match '^set (\w+)=(.*)$') { Set-Config $Matches[1] $Matches[2] }
        elseif ($s -eq 'stub-ndrc') {
            $stub = Join-Path $kit 'ndrc-stub'
            if ($onWindows) {
                $stubPath = [IO.Path]::GetFullPath("$stub.cmd")
                [IO.File]::WriteAllText($stubPath, "@echo NDRC 9.9.9 --from-json`r`n@exit /b 2`r`n", [Text.Encoding]::ASCII)
                Set-Config 'NDRC' $stubPath
            } else {
                $stubPath = [IO.Path]::GetFullPath("$stub.sh")
                [IO.File]::WriteAllText($stubPath, "#!/bin/sh`necho 'NDRC 9.9.9 --from-json'`nexit 2`n", [Text.Encoding]::ASCII)
                & chmod +x $stubPath
                Set-Config 'NDRC' $stubPath
            }
        }
        elseif ($s -eq 'cspect') {
            # Stand-in process named CSpect, outside the kit and tools\.
            $fake = [IO.Path]::GetFullPath((Join-Path (Split-Path $kit) 'CSpect.exe'))
            Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/PING.EXE') -Destination $fake -Force
            $script:spawned = Start-Process -FilePath $fake -ArgumentList '-n', '60', '127.0.0.1' -WindowStyle Hidden -PassThru
        }
        elseif ($s -eq 'bigdsf') {
            # Fill /MTX to ndrc's 255-entry ceiling with GUID text, which
            # -auto-tokens cannot compress: 20 GUIDs per entry clear 65535 bytes.
            $dsf = Join-Path $kit 'PARITY.DSF'
            $lines = [IO.File]::ReadAllLines($dsf, [Text.Encoding]::GetEncoding(28591))
            $mtx = -1; $otx = -1
            for ($i = 0; $i -lt $lines.Length; $i++) {
                if ($mtx -lt 0 -and $lines[$i] -match '^/MTX\b') { $mtx = $i }
                if ($otx -lt 0 -and $lines[$i] -match '^/OTX\b') { $otx = $i }
            }
            $have = @($lines[$mtx..$otx] | Where-Object { $_ -match '^/\d+' }).Count
            $pad = @()
            for ($i = $have; $i -lt 255; $i++) {
                $text = (1..20 | ForEach-Object { [guid]::NewGuid().ToString('N') }) -join ' '
                $pad += "/$i `"$text`""
            }
            $out = $lines[0..($otx - 1)] + $pad + $lines[$otx..($lines.Length - 1)]
            [IO.File]::WriteAllLines($dsf, $out, [Text.Encoding]::GetEncoding(28591))
        }
        else { throw "negative: unknown setup step '$s'" }
    }
}
function Run-Build {
    Push-Location $kit
    # A native tool's stderr becomes a terminating error under -Stop merged
    # with 2>&1, even on exit code 0 (parity.ps1's Invoke-Launcher note).
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($onWindows) {
            $drv = [IO.Path]::GetFullPath((Join-Path (Split-Path $kit) 'launch-neg.cmd'))
            $kitFull = [IO.Path]::GetFullPath($kit)
            [IO.File]::WriteAllText($drv, "@cd /d `"$kitFull`"`r`n@call `"$kitFull/BUILD.BAT`" < nul`r`n@exit /b %ERRORLEVEL%`r`n", [Text.Encoding]::ASCII)
            $out = (& cmd /c $drv 2>&1 | ForEach-Object { "$_" }) -join "`n"
        } else { $out = (& sh ./build.sh 2>&1 | ForEach-Object { "$_" }) -join "`n" }
        return @{ Code = $LASTEXITCODE; Out = $out }
    } finally { $ErrorActionPreference = $prevEap; Pop-Location }
}
$skipped = 0
foreach ($case in $cases) {
    $name, $setup, $expect = $case.Split('|', 3)
    if (-not $onWindows -and $setup -match '(^|;)\s*cspect\s*($|;)') { $skipped++; Write-Host "negative: $name skipped (Windows only)"; continue }
    $script:spawned = $null
    try {
        Prepare
        Apply-Setup $setup
        # Counted after setup: a case's own stand-in CSpect is in both counts.
        $before = @(Get-Process -Name CSpect -ErrorAction SilentlyContinue).Count
        $r = Run-Build
        $after = @(Get-Process -Name CSpect -ErrorAction SilentlyContinue).Count
    } finally {
        if ($script:spawned) { Stop-Process -Id $script:spawned.Id -Force -ErrorAction SilentlyContinue; $script:spawned.WaitForExit() }
    }
    $want = $expect.Replace('{sep}', "$sep").Replace('{build}', $buildName) -replace '[\\/]', '/'
    $wantWarn = $want.StartsWith('WARN:')
    if ($wantWarn) { $want = $want.Substring(5) }
    # A WARN case builds on Windows; elsewhere build.ps1 fails with ERROR: and the same text.
    $wantCode = if ($wantWarn -and $onWindows) { 0 } else { 1 }
    $got = $r.Out -replace '[\\/]', '/'
    $ok = ($r.Code -eq $wantCode) -and $got.Contains($want) -and ($after -eq $before)
    if ($ok) { Write-Host "negative: $name ok" }
    else {
        $failed++
        Write-Host "negative: $name FAILED (exit $($r.Code), expected exit $wantCode and substring: $want)"
        Write-Host $r.Out
    }
}
if ($failed) { Write-Host "negative: $failed case(s) failed"; exit 1 }
Write-Host "negative: $(@($cases).Count - $skipped) cases passed, $skipped skipped"
exit 0
