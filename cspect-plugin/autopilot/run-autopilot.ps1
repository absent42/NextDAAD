# Autopilot runner: builds the plugin (Release + Autopilot) and the Release NEX,
# stages each leg to build\autopilot\<leg>\ with its own CSpect copy, runs every
# script part bounded (one launch each), always kills CSpect, writes report.md.
#   -Leg A|C|D|E|Linux|All   -TimeoutSeconds N (per launch, default 120)
#   -ScriptOverride <file[,file]>  replaces the part list of one leg (A, D or E),
#                                  e.g. -Leg A -ScriptOverride cspect-plugin\autopilot\scripts\smoke.txt
# A leg whose script is missing is skipped ("no script yet"). Optional seed:
# scripts\leg<X>.seed.txt is staged as DEBUGGER.local.TXT. Script lines
# "# glance: <text>" join the owner glance list in the report.
param([string]$Leg = '', [int]$TimeoutSeconds = 120, [string[]]$ScriptOverride = @())
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\staging.ps1"
$ApRepo = (Resolve-Path "$PSScriptRoot\..\..").Path
$ApScripts = Join-Path $PSScriptRoot 'scripts'
$ApRoot = Join-Path $ApRepo 'build\autopilot'
$ApCs40 = 'D:\ZXNextDev\cspect'
$ApCs331 = Join-Path $ApRepo 'tools\CSpect'
$ApBin = Join-Path $ApRepo 'build\cspect-plugin\bin\NextDAADDebug'

# Script parts per leg; each part is one CSpect launch in the same leg folder.
$LegTable = @{
    A = @{ CSpect = $ApCs40; Parts = @('legA-1.txt', 'legA-2.txt') }
    C = @{ CSpect = $ApCs331; Parts = @() }
    D = @{ CSpect = $ApCs40; Parts = @('legD.txt'); Variant = 'StaleDsm' }
    E = @{ CSpect = $ApCs40; Parts = @('legE.txt'); Variant = 'DebugSym' }
}
$ApDebugSym = Join-Path $ApRepo 'build\NEXTDAAD.DEBUG.SYM'
$DefaultGlance = @(
    'drag the debugger window, quit and relaunch: it reopens where it was left',
    'the window close box',
    'hover feedback on buttons and list rows')

function Read-Shared([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    }
    catch { return $null }
}

function Get-LegScripts([string]$leg, [string[]]$override, [string]$dir = $ApScripts) {
    $names = if ($override -and $override.Count) { $override } else { $LegTable[$leg].Parts }
    $parts = @(); $missing = @()
    foreach ($n in $names) {
        $p = if ([IO.Path]::IsPathRooted($n)) { $n } elseif (Test-Path -LiteralPath (Join-Path $ApRepo $n)) { Join-Path $ApRepo $n } else { Join-Path $dir $n }
        if (Test-Path -LiteralPath $p) { $parts += (Resolve-Path -LiteralPath $p).Path } else { $missing += (Split-Path $n -Leaf) }
    }
    return [pscustomobject]@{ Parts = $parts; Missing = $missing }
}

# Parses one autopilot-result.txt into a totals/FAIL/FACT record.
function New-PartRecord([string]$leg, [string]$part, [string]$resultFile, [string]$dir, [bool]$timedOut) {
    $rec = [pscustomobject]@{ Leg = $leg; Part = $part; Status = 'FAIL'; Steps = 0; Pass = 0; Fail = 0; Skipped = 0; Note = ''; Fails = @(); Facts = @(); Dir = $dir }
    $text = Read-Shared $resultFile
    if ($null -eq $text) { $rec.Note = if ($timedOut) { 'no result file (timed out)' } else { 'no result file' }; return $rec }
    $done = $null
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -match '^STEP (\d+) (\w+) line (\d+) \| (.*?) \| expected (.*) \| actual (.*)$') {
            $rec.Steps++
            switch ($Matches[2]) {
                'PASS' { $rec.Pass++ }
                'FAIL' { $rec.Fail++; $rec.Fails += [pscustomobject]@{ Step = [int]$Matches[1]; Line = $Matches[3]; Raw = $Matches[4]; Expected = $Matches[5]; Actual = $Matches[6] } }
                default { $rec.Skipped++ }
            }
        }
        elseif ($l -match '^FACT ([^=]+)=(.*)$') { $rec.Facts += [pscustomobject]@{ Name = $Matches[1]; Value = $Matches[2] } }
        elseif ($l -match '^DONE failures=(\d+)') { $done = [int]$Matches[1] }
    }
    if ($null -eq $done) { $rec.Note = if ($timedOut) { 'no DONE line (timed out)' } else { 'no DONE line' }; return $rec }
    $rec.Note = "DONE failures=$done"
    if ($done -eq 0 -and $rec.Fail -eq 0) { $rec.Status = 'PASS' }
    return $rec
}

function Cell([string]$s) { return ($s -replace '\|', '\|') }

function New-AutopilotReport($parts, $skips, $legC, $glance, [string]$stamp) {
    $o = New-Object Collections.Generic.List[string]
    $failing = @($parts | Where-Object { $_.Status -ne 'PASS' }).Count + @($legC | Where-Object { -not $_.Pass }).Count
    $o.Add('# CSpect autopilot report'); $o.Add('')
    $o.Add("Run: $stamp"); $o.Add('')
    $o.Add($(if ($failing) { "Overall: FAIL ($failing failing parts)" } else { 'Overall: PASS' })); $o.Add('')
    $o.Add('## Totals'); $o.Add('')
    $o.Add('| Leg | Part | Result | Steps | Pass | Fail | Skipped | Note |')
    $o.Add('|---|---|---|---|---|---|---|---|')
    foreach ($p in $parts) { $o.Add("| $($p.Leg) | $(Cell $p.Part) | $($p.Status) | $($p.Steps) | $($p.Pass) | $($p.Fail) | $($p.Skipped) | $(Cell $p.Note) |") }
    foreach ($c in $legC) {
        $note = if ($c.Pass) { 'TooOld logged, trace first line matches' } else { $c.Reasons -join '; ' }
        $o.Add("| $($c.Leg) | - | $(if ($c.Pass) { 'PASS' } else { 'FAIL' }) | 0 | 0 | 0 | 0 | $(Cell $note) |")
    }
    foreach ($s in $skips) { $o.Add("| $($s.Leg) | - | SKIPPED | 0 | 0 | 0 | 0 | $(Cell $s.Reason) |") }
    $o.Add(''); $o.Add('## Failures'); $o.Add('')
    $any = $false
    foreach ($p in $parts) {
        foreach ($f in $p.Fails) {
            $any = $true
            $o.Add("- $($p.Leg) $($p.Part) STEP $($f.Step) line $($f.Line): ``$($f.Raw)`` - expected $($f.Expected) - actual $($f.Actual)")
            $o.Add('  dump: ' + (Join-Path $p.Dir ('dumps\' + $f.Step.ToString('D3') + '.txt')))
        }
        if ($p.Note -notlike 'DONE*') { $any = $true; $o.Add("- $($p.Leg) $($p.Part): $($p.Note)") }
    }
    foreach ($c in $legC) { if (-not $c.Pass) { $any = $true; $o.Add("- $($c.Leg): $($c.Reasons -join '; ')") } }
    if (-not $any) { $o.Add('none') }
    $o.Add(''); $o.Add('## Facts (measurements for the owner to rule on, never FAILs)'); $o.Add('')
    $o.Add('| Leg | Part | Fact | Value |'); $o.Add('|---|---|---|---|')
    foreach ($p in $parts) { foreach ($f in $p.Facts) { $o.Add("| $($p.Leg) | $(Cell $p.Part) | $(Cell $f.Name) | $(Cell $f.Value) |") } }
    $o.Add(''); $o.Add('## Owner glance (real-window-only, not automated)'); $o.Add('')
    foreach ($g in $glance) { $o.Add("- $g") }
    $o.Add(''); $o.Add('## Files'); $o.Add('')
    foreach ($p in $parts | Where-Object { $_.Dir }) { $o.Add("- $($p.Leg) $($p.Part): $($p.Dir) (autopilot-result.txt, dumps\, debugger.log, stdout.txt)") }
    foreach ($c in $legC) { $o.Add("- $($c.Leg): $($c.Folder) (sd\debugger.log, sd\trace.txt, stdout.txt)") }
    return ($o -join "`r`n") + "`r`n"
}

function Get-TooOldText([string]$file = (Join-Path $ApRepo 'cspect-plugin\src\PlatformFacts.cs')) {
    $m = [regex]::Match([IO.File]::ReadAllText($file), 'const string TooOld = "([^"]*)"')
    if (-not $m.Success) { throw "VersionGate.TooOld not found in $file" }
    return $m.Groups[1].Value
}

function Test-LegC([string]$log, [string]$trace, [string]$expect, [string]$tooOld) {
    $reasons = @()
    $lt = Read-Shared $log
    if ($null -eq $lt) { $reasons += 'debugger.log missing' }
    elseif (-not $lt.Contains($tooOld)) { $reasons += 'debugger.log lacks the VersionGate.TooOld text' }
    $want = @(Get-Content -LiteralPath $expect | Where-Object { $_ -and -not $_.StartsWith('#') })[0]
    $tt = Read-Shared $trace
    $got = if ($tt) { ($tt -split "`r?`n")[0] } else { '' }
    if (-not $got) { $reasons += 'trace.txt missing or empty' }
    elseif ($got -ne $want) { $reasons += "trace.txt first line: got `"$got`", want `"$want`"" }
    return [pscustomobject]@{ Leg = 'C'; Pass = ($reasons.Count -eq 0); Reasons = $reasons; Folder = (Split-Path $log) }
}

function Get-Glance([string[]]$scripts) {
    $g = @($DefaultGlance)
    foreach ($s in $scripts) {
        foreach ($l in (Get-Content -LiteralPath $s)) { if ($l -match '^\s*#\s*glance:\s*(.+)$') { $g += $Matches[1].Trim() } }
    }
    return $g
}

# One bounded launch. Stops early once $doneWhen is true; CSpect is killed by id in every case.
function Invoke-CSpect([string]$csDir, [string]$legDir, [string[]]$csArgs, [hashtable]$vars, [int]$seconds, [string]$stdout, [scriptblock]$doneWhen, [object[]]$doneArgs) {
    $names = 'NEXTDAAD_DEBUG', 'NEXTDAAD_DEBUG_AUTOPILOT', 'NEXTDAAD_DEBUG_TRACE', 'NEXTDAAD_DEBUG_NOWINDOW', 'NEXTDAAD_DEBUG_SETTINGS'
    $p = $null; $timedOut = $false; $self = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($n in $names) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
        foreach ($k in $vars.Keys) { Set-Item "Env:$k" $vars[$k] }
        $p = Start-Process -FilePath (Join-Path $csDir 'CSpect.exe') -ArgumentList $csArgs -WorkingDirectory $legDir -PassThru -RedirectStandardOutput $stdout -RedirectStandardError "$stdout.err"
        $doneAt = $null
        while ($true) {
            if ($p.HasExited) { $self = $true; break }
            if ($sw.Elapsed.TotalSeconds -ge $seconds) { $timedOut = $true; break }
            if ($null -eq $doneAt -and (& $doneWhen @doneArgs)) { $doneAt = $sw.Elapsed.TotalSeconds }
            if ($null -ne $doneAt -and $sw.Elapsed.TotalSeconds -ge $doneAt + 5) { break }
            Start-Sleep -Milliseconds 250
        }
    }
    finally {
        foreach ($n in $names) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
        if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $p.WaitForExit(10000) | Out-Null }
    }
    return [pscustomobject]@{ TimedOut = $timedOut; ExitedSelf = $self; Ms = $sw.ElapsedMilliseconds }
}

# Game files for one leg into card root $g. D and E match stage-legs.ps1's
# LEGDBGSTALE (DSM ddb CRC zeroed) and LEGDBGBADSYM (DEBUG SYM, no seed).
function Copy-LegGame([string]$leg, [string]$g, [string]$nex, [string]$sym, [string]$debugSym) {
    $fx = Join-Path $ApRepo 'cspect-plugin\tests\fixtures'
    $v = $LegTable[$leg].Variant
    New-Item -ItemType Directory -Force "$g\DATA" | Out-Null
    # Kit layout DATA\GAME.DDB: the Release NEX booted E1 on CSpect with GAME.DDB only in the card root.
    Copy-Item "$fx\DBGFIX.DDB" "$g\DATA\GAME.DDB"
    Copy-Item "$fx\DBGFIX.DSM" "$g\GAME.DSM"
    Copy-Item "$fx\DBGFIX.DSF" $g
    Copy-Item $nex "$g\nextdaad.nex"
    Copy-Item $(if ($v -eq 'DebugSym') { $debugSym } else { $sym }) "$g\NEXTDAAD.SYM"
    if ($v -eq 'StaleDsm') {
        $dsm = [IO.File]::ReadAllText("$g\GAME.DSM") -replace '(?m)^ddb\t[0-9A-Fa-f]+\t', "ddb`t00000000`t"
        [IO.File]::WriteAllText("$g\GAME.DSM", $dsm, (New-Object Text.UTF8Encoding($false)))
    }
    $seed = Join-Path $ApScripts "leg$leg.seed.txt"
    if ($v -ne 'DebugSym' -and (Test-Path -LiteralPath $seed)) { Copy-Item $seed "$g\DEBUGGER.local.TXT" }
}

# Leg layout: sd\ (card root and NEXTDAAD_DEBUG folder), cspect\, parts\;
# the CSpect copy and results stay off the emulated card.
function New-LegFolder([string]$leg, [string]$csSrc) {
    $dir = Join-Path $ApRoot $leg
    Reset-StageFolder $dir $ApRoot
    $g = Join-Path $dir 'sd'
    New-Item -ItemType Directory -Force $g | Out-Null
    Copy-LegGame $leg $g "$ApRepo\build\nextdaad.nex" "$ApRepo\build\NEXTDAAD.SYM" $ApDebugSym
    Copy-CSpect $csSrc "$dir\cspect"
    Copy-Item "$ApBin\Autopilot\net48\NextDAADDebug.dll" "$dir\cspect" -Force
    Assert-AutopilotDll "$dir\cspect\NextDAADDebug.dll"
    return $dir
}

function Invoke-ScriptLeg([string]$leg, [string[]]$scripts, [int]$seconds) {
    $dir = New-LegFolder $leg $LegTable[$leg].CSpect
    $g = Join-Path $dir 'sd'
    $recs = @(); $i = 0
    foreach ($s in $scripts) {
        $i++
        $name = Split-Path $s -Leaf
        $pd = Join-Path $dir ("parts\$i-" + [IO.Path]::GetFileNameWithoutExtension($name))
        New-Item -ItemType Directory -Force $pd | Out-Null
        $res = Join-Path $g 'autopilot-result.txt'
        Remove-Item -LiteralPath $res -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath "$g\dumps") { Remove-Item -LiteralPath "$g\dumps" -Recurse -Force }
        $r = Invoke-CSpect "$dir\cspect" $g @('-w2', '-zxnext', '-esc', '-sound', "-mmc=$g\", "$g\nextdaad.nex") @{ NEXTDAAD_DEBUG = $g; NEXTDAAD_DEBUG_AUTOPILOT = $s } $seconds "$pd\stdout.txt" { param($f) $t = Read-Shared $f; $t -and $t -match '(?m)^DONE ' } @($res)
        Write-Host "leg $leg part $i ${name}: $($r.Ms) ms, $(if ($r.ExitedSelf) { 'exited by itself' } elseif ($r.TimedOut) { "killed at the $seconds s bound" } else { 'killed after DONE' })"
        if (Test-Path -LiteralPath $res) { Move-Item -LiteralPath $res $pd }
        if (Test-Path -LiteralPath "$g\dumps") { Move-Item -LiteralPath "$g\dumps" $pd }
        if (Test-Path -LiteralPath "$g\debugger.log") { Copy-Item "$g\debugger.log" $pd }
        $recs += New-PartRecord $leg $name (Join-Path $pd 'autopilot-result.txt') $pd $r.TimedOut
    }
    return $recs
}

function Invoke-LegC([int]$seconds) {
    $dir = New-LegFolder 'C' $ApCs331
    $g = Join-Path $dir 'sd'
    $tooOld = Get-TooOldText
    $log = Join-Path $g 'debugger.log'
    $trace = Join-Path $g 'trace.txt'
    $r = Invoke-CSpect "$dir\cspect" $g @('-w1', '-zxnext', '-esc', '-sound', "-mmc=$g\", "$g\nextdaad.nex") @{ NEXTDAAD_DEBUG = $g; NEXTDAAD_DEBUG_TRACE = $trace } ([Math]::Min($seconds, 30)) "$dir\stdout.txt" { param($lg, $tr, $to) $l = Read-Shared $lg; $t = Read-Shared $tr; $l -and $l.Contains($to) -and $t -and $t.Contains("`n") } @($log, $trace, $tooOld)
    Write-Host "leg C: $($r.Ms) ms, $(if ($r.ExitedSelf) { 'exited by itself' } elseif ($r.TimedOut) { 'killed at the bound' } else { 'killed after trace' })"
    $c = Test-LegC $log $trace (Join-Path $ApScripts 'legC.expect.txt') $tooOld
    $c.Folder = $dir
    return $c
}

# Linux leg: leg A on the VM over ssh (key auth). Settings {host,user,remoteDir} are read
# from this file only and never written anywhere committed.
$ApSettings = Join-Path $env:USERPROFILE '.nextdaad\autopilot.json'
$ApHashRefusal = "the VM's CSpect differs from Windows - update it first"

function Invoke-Ssh($s, [string]$cmd) {
    $ErrorActionPreference = 'Continue'
    $out = & ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 "$($s.user)@$($s.host)" $cmd
    if ($LASTEXITCODE) { throw "ssh exit $LASTEXITCODE for: $cmd" }
    return $out
}

function Invoke-Scp($s, [string[]]$from, [string]$to) {
    $ErrorActionPreference = 'Continue'
    & scp -o BatchMode=yes -o ConnectTimeout=8 -r -q @from $to
    if ($LASTEXITCODE) { throw "scp exit ${LASTEXITCODE}: $($from -join ' ') -> $to" }
}

# Settings, reachability and the CSpect hash gate; throws the refusal text.
function Get-LinuxPreflight([string]$path, [string]$localExe) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Linux leg refused: settings file $path missing (needs host, user, remoteDir)" }
    try { $s = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { $s = $null }
    if ($null -eq $s -or $s -isnot [pscustomobject]) { throw "Linux leg refused: $path is not valid JSON" }
    foreach ($f in 'host', 'user', 'remoteDir') {
        $v = $s.PSObject.Properties[$f]
        if ($null -eq $v -or $v.Value -isnot [string] -or -not $v.Value) { throw "Linux leg refused: $path lacks '$f'" }
    }
    if ($s.host -notmatch '^[A-Za-z0-9._-]+$' -or $s.user -notmatch '^[A-Za-z0-9._-]+$') { throw "Linux leg refused: host or user in $path has unexpected characters" }
    if ($s.remoteDir -notmatch '^(~/|/)[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*/?$' -or $s.remoteDir -match '(^|/)\.\.?(/|$)') { throw "Linux leg refused: remoteDir must be ~/<dir> or /<dir> (letters, digits, . _ - only)" }
    try { Invoke-Ssh $s 'true' | Out-Null } catch { throw "Linux leg refused: VM unreachable over ssh with key auth ($($_.Exception.Message))" }
    $vmHome = "$(Invoke-Ssh $s 'echo $HOME')".Trim()
    if ($vmHome -notmatch '^/') { throw "Linux leg refused: VM home not found" }
    $remote = $(if ($s.remoteDir.StartsWith('~/')) { $vmHome.TrimEnd('/') + $s.remoteDir.Substring(1) } else { $s.remoteDir }).TrimEnd('/')
    try { $vm = "$(Invoke-Ssh $s 'sha256sum ~/nextdaad/tools/CSpect/CSpect.exe')".Trim() } catch { throw "Linux leg refused: no CSpect.exe in ~/nextdaad/tools/CSpect on the VM" }
    $win = (Get-FileHash -LiteralPath $localExe -Algorithm SHA256).Hash
    if (($vm -split '\s+')[0] -ne $win) { throw $ApHashRefusal }
    return [pscustomobject]@{ Settings = $s; Remote = $remote }
}

function New-RefusedRecord([string]$msg) {
    return [pscustomobject]@{ Leg = 'Linux'; Part = '-'; Status = 'FAIL'; Steps = 0; Pass = 0; Fail = 0; Skipped = 0; Note = $msg; Fails = @(); Facts = @(); Dir = '' }
}

# Records from the pulled-back parts\<i>-<name>\ (status.txt: exit=<rc>, 124 = timeout bound).
function Get-LinuxRecords([string]$partsDir, [string[]]$names) {
    $recs = @(); $i = 0
    foreach ($n in $names) {
        $i++
        $pd = Join-Path $partsDir ("$i-" + [IO.Path]::GetFileNameWithoutExtension($n))
        $st = Read-Shared (Join-Path $pd 'status.txt')
        $timedOut = $st -and $st -match 'exit=(124|137)\b'
        $recs += New-PartRecord 'Linux' $n (Join-Path $pd 'autopilot-result.txt') $pd ([bool]$timedOut)
    }
    return $recs
}

# Linux variant of a script: drops "# windows-only" .. "# end windows-only" blocks and
# un-comments "# linux: <line>" lines (the window cannot close under mono).
function Convert-LinuxScript([string]$src, [string]$dest) {
    $out = New-Object Collections.Generic.List[string]
    $skip = $false
    foreach ($l in ([IO.File]::ReadAllText($src, [Text.Encoding]::UTF8) -split "`r?`n")) {
        if ($l -cmatch '^\s*#\s*windows-only\s*$') { $skip = $true; continue }
        if ($l -cmatch '^\s*#\s*end windows-only\s*$') { $skip = $false; continue }
        if ($skip) { continue }
        if ($l -cmatch '^\s*#\s*linux:\s?(.*)$') { $out.Add($Matches[1]); continue }
        $out.Add($l)
    }
    [IO.File]::WriteAllText($dest, ($out -join "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-LinuxLeg([int]$seconds) {
    try { $pf = Get-LinuxPreflight $ApSettings (Join-Path $ApCs40 'CSpect.exe') }
    catch { Write-Host $_.Exception.Message; return @(New-RefusedRecord $_.Exception.Message) }
    $sc = Get-LegScripts 'A' @()
    if ($sc.Missing.Count) { return @(New-RefusedRecord "no script yet: $($sc.Missing -join ', ')") }
    $dir = Join-Path $ApRoot 'Linux'
    Reset-StageFolder $dir $ApRoot
    $st = Join-Path $dir 'stage'
    New-Item -ItemType Directory -Force "$st\sd", "$st\scripts" | Out-Null
    Copy-LegGame 'A' "$st\sd" "$ApRepo\build\nextdaad.nex" "$ApRepo\build\NEXTDAAD.SYM" $ApDebugSym
    # CSpect 4.0 under mono: with DATA\GAME.DDB only the Release NEX stops at E1 (measured 2026-10-25);
    # its boot falls back to the launch folder, so a root copy is added.
    Copy-Item "$st\sd\DATA\GAME.DDB" "$st\sd\GAME.DDB"
    Copy-Item "$ApBin\Autopilot\net48\NextDAADDebug.dll" $st
    Assert-AutopilotDll "$st\NextDAADDebug.dll"
    $names = @($sc.Parts | ForEach-Object { Split-Path $_ -Leaf })
    foreach ($p in $sc.Parts) { Convert-LinuxScript $p (Join-Path "$st\scripts" (Split-Path $p -Leaf)) }
    # LF only: a CRLF checkout of the script would not run under bash.
    $sh = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'linux-leg.sh')) -replace "`r", ''
    [IO.File]::WriteAllText("$st\linux-leg.sh", $sh, (New-Object Text.UTF8Encoding($false)))
    $s = $pf.Settings
    $tgt = "$($s.user)@$($s.host)"
    $run = "$($pf.Remote)/legA"
    $sh = "bash '$($pf.Remote)/linux-leg.sh'"
    Push-Location $st
    try {
        Invoke-Ssh $s "mkdir -p '$($pf.Remote)'" | Out-Null
        Invoke-Scp $s @('linux-leg.sh') "${tgt}:$($pf.Remote)/"
        Invoke-Ssh $s "$sh reset '$run'" | Out-Host
        Invoke-Scp $s @('sd', 'scripts', 'NextDAADDebug.dll') "${tgt}:$run/"
        try { Invoke-Ssh $s "$sh run '$run' $seconds $($names -join ' ')" | Out-Host }
        catch { Write-Host "Linux run: $($_.Exception.Message)" }
    }
    finally {
        try { Invoke-Ssh $s "$sh kill '$run'" | Out-Host } catch { Write-Host "Linux kill: $($_.Exception.Message)" }
        Pop-Location
    }
    try { Invoke-Scp $s @("${tgt}:$run/parts") $dir } catch { Write-Host "Linux results: $($_.Exception.Message)" }
    return Get-LinuxRecords (Join-Path $dir 'parts') $names
}

if ($MyInvocation.InvocationName -eq '.') { return }

$legs = switch ($Leg) {
    'All' { 'A', 'C', 'D', 'E', 'Linux' }
    { $_ -in 'A', 'C', 'D', 'E', 'Linux' } { $Leg }
    default { throw "-Leg must be A, C, D, E, Linux or All (got '$Leg')" }
}
if ($ScriptOverride.Count -and ($legs.Count -ne 1 -or $legs -notin 'A', 'D', 'E')) { throw '-ScriptOverride needs exactly one of -Leg A, D or E' }

$parts = @(); $skips = @(); $legC = @(); $used = @()
if ($legs.Count) {
    $proj = Join-Path $ApRepo 'cspect-plugin\NextDAADDebug.csproj'
    foreach ($cfg in 'Release', 'Autopilot') {
        & dotnet build $proj -c $cfg "-p:CSpectDir=$ApCs40" | Out-Host
        if ($LASTEXITCODE) { throw "plugin $cfg build failed" }
    }
    # DEBUG first for leg E's mismatched SYM, then Release for the staged NEX and SYM (stage-legs.ps1 order).
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ApRepo 'build.ps1') | Out-Host
    if ($LASTEXITCODE) { throw 'build.ps1 (DEBUG) failed' }
    Copy-Item (Join-Path $ApRepo 'build\NEXTDAAD.SYM') $ApDebugSym -Force
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ApRepo 'build.ps1') -Release | Out-Host
    if ($LASTEXITCODE) { throw 'build.ps1 -Release failed' }
    New-Item -ItemType Directory -Force $ApRoot | Out-Null
}
foreach ($l in $legs) {
    if ($l -eq 'Linux') {
        $sc = Get-LegScripts 'A' @()
        if (-not $sc.Missing.Count) { $used += $sc.Parts }
        $parts += Invoke-LinuxLeg $TimeoutSeconds
        continue
    }
    if ($l -eq 'C') { $legC += Invoke-LegC $TimeoutSeconds; continue }
    $sc = Get-LegScripts $l $ScriptOverride
    if ($sc.Missing.Count) {
        "leg ${l}: no script yet ($($sc.Missing -join ', '))"
        $skips += [pscustomobject]@{ Leg = $l; Reason = "no script yet: $($sc.Missing -join ', ')" }
        continue
    }
    $used += $sc.Parts
    $parts += Invoke-ScriptLeg $l $sc.Parts $TimeoutSeconds
}
$stamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ', commit ' + (& git -C $ApRepo rev-parse --short HEAD)
$md = New-AutopilotReport $parts $skips $legC (Get-Glance $used) $stamp
New-Item -ItemType Directory -Force $ApRoot | Out-Null
$report = Join-Path $ApRoot 'report.md'
[IO.File]::WriteAllText($report, $md, (New-Object Text.UTF8Encoding($false)))
$md
"report: $report"
if ($md -match '(?m)^Overall: FAIL') { exit 1 }
