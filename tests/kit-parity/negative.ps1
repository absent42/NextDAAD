# Each case sets up a fresh fixture kit one way, runs the launchers and
# asserts the exit code and message (exit 1 unless OK: or a Windows WARN:).
# Case lines: name|setup|expect[|verbs[|files]], see negative/cases.txt.
param([string]$ToolsDir = '', [string]$FfmpegDir = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or ($IsWindows -eq $true)
$sep = [IO.Path]::DirectorySeparatorChar
$buildName = if ($onWindows) { 'BUILD.BAT' } else { 'build.sh' }
$kit = Join-Path $root 'tests/out/kit parity/kit'
$cases = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'negative/cases.txt') -Encoding ASCII | Where-Object { $_ -and -not $_.StartsWith('#') }
$failed = 0

function Prepare([string]$Layout = '') {
    # Hashtable splat: an array splat of dash-prefixed strings binds
    # positionally, not by name, so -PrepareOnly would land in $ToolsDir.
    $prepArgs = @{ PrepareOnly = $true }
    if ($Layout) { $prepArgs.Layout = $Layout }
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
        elseif ($s -match '^write (\S+) (.*)$') {
            $p = Join-Path $kit $Matches[1]
            New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
            [IO.File]::WriteAllText($p, $Matches[2].Replace('\n', "`n"), [Text.Encoding]::ASCII)
        }
        elseif ($s -eq 'layout folder') { throw "negative: 'layout folder' must be the first setup step" }
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
            if ($onWindows) {
                Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/PING.EXE') -Destination $fake -Force
                $script:spawned = Start-Process -FilePath $fake -ArgumentList '-n', '60', '127.0.0.1' -WindowStyle Hidden -PassThru
            } else {
                # Copy-Item does not promise to keep the mode; set it explicitly.
                Copy-Item -LiteralPath '/bin/sleep' -Destination $fake -Force
                & chmod +x $fake
                $script:spawned = Start-Process -FilePath $fake -ArgumentList '600' -PassThru
            }
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
# Verb build, run, clean or debug: the kit launcher of that name.
function Run-Launcher([string]$Verb) {
    if ($Verb -notin 'build', 'run', 'clean', 'debug') { throw "negative: unknown verb '$Verb'" }
    Push-Location $kit
    # A native tool's stderr becomes a terminating error under -Stop merged
    # with 2>&1, even on exit code 0 (parity.ps1's Invoke-Launcher note).
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($onWindows) {
            $drv = [IO.Path]::GetFullPath((Join-Path (Split-Path $kit) 'launch-neg.cmd'))
            $kitFull = [IO.Path]::GetFullPath($kit)
            [IO.File]::WriteAllText($drv, "@cd /d `"$kitFull`"`r`n@call `"$kitFull/$($Verb.ToUpperInvariant()).BAT`" < nul`r`n@exit /b %ERRORLEVEL%`r`n", [Text.Encoding]::ASCII)
            $out = (& cmd /c $drv 2>&1 | ForEach-Object { "$_" }) -join "`n"
        } else { $out = (& sh "./$Verb.sh" 2>&1 | ForEach-Object { "$_" }) -join "`n" }
        return @{ Code = $LASTEXITCODE; Out = $out }
    } finally { $ErrorActionPreference = $prevEap; Pop-Location }
}
$skipped = 0
# name|setup|expect[|verbs[|files]]
foreach ($case in $cases) {
    $fields = $case.Split('|', 5)
    $name, $setup, $expect = $fields[0..2]
    $verbs = @('build')
    if ($fields.Count -gt 3 -and $fields[3].Trim()) { $verbs = @($fields[3].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $files = @()
    if ($fields.Count -gt 4) { $files = @($fields[4].Split(' ') | Where-Object { $_ }) }
    $layout = ''
    if ($setup -match '^\s*layout folder\s*(;|$)') { $layout = 'folder'; $setup = $setup -replace '^\s*layout folder\s*;?', '' }
    $script:spawned = $null
    try {
        Prepare $layout
        if ($setup.Trim()) { Apply-Setup $setup }
        # Counted after setup: a case's own stand-in CSpect is in both counts.
        # Linux names the process CSpect.exe (its command line, via Test-CSpectRunning's pgrep match).
        $before = @(Get-Process -Name 'CSpect*' -ErrorAction SilentlyContinue).Count
        foreach ($v in $verbs) { $r = Run-Launcher $v }
        $after = @(Get-Process -Name 'CSpect*' -ErrorAction SilentlyContinue).Count
    } finally {
        if ($script:spawned) { Stop-Process -Id $script:spawned.Id -Force -ErrorAction SilentlyContinue; $script:spawned.WaitForExit() }
    }
    $want = $expect.Replace('{sep}', "$sep").Replace('{build}', $buildName) -replace '[\\/]', '/'
    $wantWarn = $want.StartsWith('WARN:')
    $wantOk = $want.StartsWith('OK:')
    if ($wantWarn) { $want = $want.Substring(5) }
    if ($wantOk) { $want = $want.Substring(3) }
    # A WARN case builds on Windows; elsewhere build.ps1 fails with ERROR: and the same text.
    $wantCode = if ($wantOk -or ($wantWarn -and $onWindows)) { 0 } else { 1 }
    $got = $r.Out -replace '[\\/]', '/'
    $fileErr = @()
    foreach ($fspec in $files) {
        $fp = Join-Path $kit $fspec.Substring(1)
        if ($fspec.StartsWith('+') -and -not (Test-Path -LiteralPath $fp)) { $fileErr += "missing $($fspec.Substring(1))" }
        elseif ($fspec.StartsWith('-') -and (Test-Path -LiteralPath $fp)) { $fileErr += "unexpected $($fspec.Substring(1))" }
        elseif ($fspec[0] -notin '+', '-') { throw "negative: bad files entry '$fspec'" }
    }
    $ok = ($r.Code -eq $wantCode) -and $got.Contains($want) -and ($after -eq $before) -and ($fileErr.Count -eq 0)
    if ($fileErr.Count) { Write-Host "negative: $name files: $($fileErr -join ', ')" }
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
