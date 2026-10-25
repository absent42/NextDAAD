# Autopilot runner: builds the plugin (Release + Autopilot) and the Release NEX,
# stages each leg to build\autopilot\<leg>\ with its own CSpect copy, runs every
# script part bounded (one launch each), always kills CSpect, writes report.md.
#   -Leg A|C|D|E|K|Linux|All   -TimeoutSeconds N (per launch, default 120)
#   Leg K builds DBGKIT in a scratch kit with lib\debug.ps1 -NoLaunch and runs its launch line.
#   -ScriptOverride <file[,file]>  replaces the part list of one leg (A, D, E or K),
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
# Leg C needs a below-4.0 CSpect (tools\CSpect is 4.0 now); only read.
$ApCsOld = 'D:\ZXNextDev\CSpect3_4_1_0_BETA'
$ApBin = Join-Path $ApRepo 'build\cspect-plugin\bin\NextDAADDebug'

# Script parts per leg; each part is one CSpect launch in the same leg folder.
$LegTable = @{
    A = @{ CSpect = $ApCs40; Parts = @('legA-1.txt', 'legA-2.txt') }
    C = @{ CSpect = $ApCsOld; Parts = @() }
    D = @{ CSpect = $ApCs40; Parts = @('legD.txt'); Variant = 'StaleDsm' }
    E = @{ CSpect = $ApCs40; Parts = @('legE.txt'); Variant = 'DebugSym' }
    K = @{ CSpect = $ApCs40; Parts = @('legK.txt') }
}
$ApKitSrc = Join-Path $ApRepo 'authoring-kit'
$ApFixK = Join-Path $ApRepo 'cspect-plugin\tests\fixtures\dbgkit\DBGKIT'
$LegKLinuxReason = "not run on Linux - CSpect under mono ignores F_CHDIR, so a kit game (DATA\ layout) stops at E1"
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

# Script steps as ScriptParser counts them: every line whose first non-blank character is not '#'.
function Get-ScriptStepCount([string]$path) {
    return @([IO.File]::ReadAllLines($path) | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') }).Count
}

# Parses one autopilot-result.txt into a totals/FAIL/FACT record; $want = the script's step count.
# PASS needs DONE failures=0, no FAIL line and exactly $want STEP lines.
function New-PartRecord([string]$leg, [string]$part, [string]$resultFile, [string]$dir, [bool]$timedOut, [int]$want = -1) {
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
    if ($rec.Steps -eq 0) { $rec.Note = "no steps reported (DONE failures=$done)"; return $rec }
    if ($want -lt 1 -or $rec.Steps -ne $want) { $rec.Note = "steps: $($rec.Steps) reported, script has $(if ($want -lt 1) { 'unknown' } else { $want }) (DONE failures=$done)"; return $rec }
    $rec.Note = "DONE failures=$done"
    if ($done -eq 0 -and $rec.Fail -eq 0) { $rec.Status = 'PASS' }
    return $rec
}

function Cell([string]$s) { return ($s -replace '\|', '\|') }

function New-AutopilotReport($parts, $skips, $legC, $glance, [string]$stamp) {
    $o = New-Object Collections.Generic.List[string]
    $failing = @($parts | Where-Object { $_.Status -ne 'PASS' }).Count + @($legC | Where-Object { -not $_.Pass }).Count
    $ran = @($parts).Count + @($legC).Count
    $o.Add('# CSpect autopilot report'); $o.Add('')
    $o.Add("Run: $stamp"); $o.Add('')
    $o.Add($(if ($failing) { "Overall: FAIL ($failing failing parts)" } elseif (-not $ran) { 'Overall: FAIL (nothing ran)' } else { 'Overall: PASS' })); $o.Add('')
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
            $dump = Join-Path $p.Dir ('dumps\' + $f.Step.ToString('D3') + '.txt')
            $o.Add($(if (Test-Path -LiteralPath $dump) { "  dump: $dump" } else { '  dump: none written' }))
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
    foreach ($p in $parts | Where-Object { $_.Dir }) {
        $what = if ($p.PSObject.Properties['Files']) { $p.Files } else { 'autopilot-result.txt, dumps\, debugger.log, stdout.txt' }
        $o.Add("- $($p.Leg) $($p.Part): $($p.Dir) ($what)")
    }
    foreach ($c in $legC | Where-Object { $_.Folder }) { $o.Add("- $($c.Leg): $($c.Folder) (sd\debugger.log, sd\trace.txt, stdout.txt)") }
    return ($o -join "`r`n") + "`r`n"
}

function Get-TooOldText([string]$file = (Join-Path $ApRepo 'cspect-plugin\src\PlatformFacts.cs')) {
    $m = [regex]::Match([IO.File]::ReadAllText($file), 'const string TooOld = "([^"]+)"')
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
    elseif ($got -cne $want) { $reasons += "trace.txt first line: got `"$got`", want `"$want`"" }
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
# The caller's NEXTDAAD_DEBUG* variables are cleared for the launch and restored after it.
function Invoke-CSpect([string]$csDir, [string]$legDir, [string[]]$csArgs, [hashtable]$vars, [int]$seconds, [string]$stdout, [scriptblock]$doneWhen, [object[]]$doneArgs) {
    $names = 'NEXTDAAD_DEBUG', 'NEXTDAAD_DEBUG_AUTOPILOT', 'NEXTDAAD_DEBUG_TRACE', 'NEXTDAAD_DEBUG_NOWINDOW', 'NEXTDAAD_DEBUG_SETTINGS'
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
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
        # [NullString] removes an unset one: newer .NET keeps '' as an empty variable.
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $(if ($null -ne $saved[$n]) { $saved[$n] } else { [NullString]::Value }), 'Process') }
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
    return Invoke-LegParts $leg $dir $g $g @('-w2', '-zxnext', '-esc', '-sound', "-mmc=$g\", "$g\nextdaad.nex") $scripts $seconds
}

# One bounded launch per script part, cwd $cwd; $g is the NEXTDAAD_DEBUG folder, where results land
# before they move to $dir\parts\.
function Invoke-LegParts([string]$leg, [string]$dir, [string]$g, [string]$cwd, [string[]]$csArgs, [string[]]$scripts, [int]$seconds) {
    $recs = @(); $i = 0
    foreach ($s in $scripts) {
        $i++
        $name = Split-Path $s -Leaf
        $pd = Join-Path $dir ("parts\$i-" + [IO.Path]::GetFileNameWithoutExtension($name))
        New-Item -ItemType Directory -Force $pd | Out-Null
        $res = Join-Path $g 'autopilot-result.txt'
        Remove-Item -LiteralPath $res -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath "$g\dumps") { Remove-StagedTree "$g\dumps" $dir }
        $r = Invoke-CSpect "$dir\cspect" $cwd $csArgs @{ NEXTDAAD_DEBUG = $g; NEXTDAAD_DEBUG_AUTOPILOT = $s } $seconds "$pd\stdout.txt" { param($f) $t = Read-Shared $f; $t -and $t -match '(?m)^DONE ' } @($res)
        Write-Host "leg $leg part $i ${name}: $($r.Ms) ms, $(if ($r.ExitedSelf) { 'exited by itself' } elseif ($r.TimedOut) { "killed at the $seconds s bound" } else { 'killed after DONE' })"
        if (Test-Path -LiteralPath $res) { Move-Item -LiteralPath $res $pd }
        if (Test-Path -LiteralPath "$g\dumps") { Move-Item -LiteralPath "$g\dumps" $pd }
        if (Test-Path -LiteralPath "$g\debugger.log") { Copy-Item "$g\debugger.log" $pd }
        $recs += New-PartRecord $leg $name (Join-Path $pd 'autopilot-result.txt') $pd $r.TimedOut (Get-ScriptStepCount $s)
    }
    return $recs
}

# Refusal text when $csDir's CSpect.exe is not older than 4.0 (or unreadable), else $null;
# an upgraded leg C CSpect must never pass the version gate check vacuously.
function Get-LegCVersionRefusal([string]$csDir) {
    $exe = Join-Path $csDir 'CSpect.exe'
    try { $v = [Reflection.AssemblyName]::GetAssemblyName($exe).Version }
    catch { return "leg C needs a CSpect older than 4.0 - cannot read the version of $exe" }
    if ($v -ge [Version]'4.0') { return "leg C needs a CSpect older than 4.0 - found $v" }
    return $null
}

function Invoke-LegC([int]$seconds) {
    $refusal = Get-LegCVersionRefusal $ApCsOld
    if ($refusal) {
        Write-Host $refusal
        return [pscustomobject]@{ Leg = 'C'; Pass = $false; Reasons = @($refusal); Folder = $null }
    }
    $dir = New-LegFolder 'C' $ApCsOld
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

# ---- Leg K: DBGKIT built and launched by the kit's own lib\debug.ps1 ----

# Scratch kit in $kit (marked; $root holds it): the Windows kit file list, DBGKIT with the
# leg K seed, and CONFIG.local.BAT selecting DBGKIT and the CSpect in $csDir. Returns the game folder.
function New-LegKKit([string]$kit, [string]$root, [string]$csDir) {
    Reset-StageFolder $kit $root
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $files = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ApRepo 'scripts\kit-files.ps1') -Platform windows | Where-Object { $_ }) }
    finally { $ErrorActionPreference = $eap }
    if ($LASTEXITCODE -or $files.Count -lt 10) { throw "scripts\kit-files.ps1 -Platform windows failed ($LASTEXITCODE)" }
    Copy-ListedFiles $ApKitSrc $kit $files
    $g = Join-Path $kit 'DBGKIT'
    Copy-Item -LiteralPath $ApFixK $g -Recurse
    Copy-Item -LiteralPath (Join-Path $ApScripts 'legK.seed.txt') (Join-Path $g 'DEBUGGER.local.TXT')
    [IO.File]::WriteAllLines((Join-Path $kit 'CONFIG.local.BAT'), [string[]]@('SET GAME=DBGKIT', 'SET RUN=0', 'SET EMULATOR=cspect', "SET CSPECTDIR=$csDir"), [Text.Encoding]::ASCII)
    return $g
}

# A kit script as its launcher runs it (powershell -File, cwd = kit root).
function Invoke-KitScript([string]$kit, [string]$script, [string[]]$scriptArgs = @()) {
    Push-Location -LiteralPath $kit
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File "lib\$script" @scriptArgs 2>&1 | ForEach-Object { "$_" }); $rc = $LASTEXITCODE }
    finally { $ErrorActionPreference = $eap; Pop-Location }
    $global:LASTEXITCODE = 0
    return [pscustomobject]@{ Rc = $rc; Lines = $out }
}

function Get-KitTree([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return '' }
    $root = (Resolve-Path -LiteralPath $dir).Path.TrimEnd('\')
    $l = New-Object Collections.Generic.List[string]
    foreach ($f in Get-ChildItem -LiteralPath $root -File -Recurse -Force) { $l.Add($f.FullName.Substring($root.Length + 1)) }
    $l.Sort([StringComparer]::OrdinalIgnoreCase)
    return ($l -join '|')
}

function Read-Dsm([string]$path) {
    $d = [pscustomobject]@{ Files = @{}; Entries = @{}; Conds = New-Object Collections.Generic.List[object] }
    foreach ($l in [IO.File]::ReadAllLines($path)) {
        $f = $l -split "`t"
        if ($f[0] -ceq 'file') { $d.Files[[int]$f[1]] = $f[2] }
        elseif ($f[0] -ceq 'entry') { $d.Entries[[Convert]::ToInt32($f[1], 16)] = [pscustomobject]@{ File = [int]$f[2]; Line = [int]$f[3]; Raw = $l } }
        elseif ($f[0] -ceq 'cond') { $d.Conds.Add([pscustomobject]@{ Off = [Convert]::ToInt32($f[1], 16); Entry = [Convert]::ToInt32($f[2], 16); File = [int]$f[3]; Line = [int]$f[4]; Raw = $l }) }
    }
    return $d
}

function Get-DsmFile($m, [string]$path) {
    foreach ($k in $m.Files.Keys) { if (($m.Files[$k] -replace '\\', '/') -ieq ($path -replace '\\', '/')) { return [int]$k } }
    return -1
}

function Find-SrcLine([string[]]$src, [string]$re) {
    for ($i = 0; $i -lt $src.Count; $i++) { if ($src[$i] -cmatch $re) { return $i + 1 } }
    throw "DBGKIT fixture line /$re/ not found"
}

# The first offset whose records include one owned by each entry headed on lines $heads; $null if none.
function Find-SharedOffset($m, [int]$file, [int[]]$heads) {
    $own = @{}
    foreach ($k in $m.Entries.Keys) { $e = $m.Entries[$k]; if ($e.File -eq $file -and $heads -contains $e.Line) { $own[$e.Line] = $k } }
    if ($own.Count -ne $heads.Count) { return $null }
    foreach ($grp in ($m.Conds | Group-Object Off | Sort-Object { [int]$_.Name })) {
        $es = @($grp.Group | ForEach-Object { $_.Entry })
        if (@($heads | Where-Object { $es -notcontains $own[$_] }).Count -eq 0) {
            return [pscustomobject]@{ Off = [int]$grp.Name; Owners = $own; Recs = @($grp.Group) }
        }
    }
    return $null
}

# What legK.txt relies on, read from the kit-built maps in $g: GO A / GO B (bodies written apart)
# and SEE A / SEE B (synonym headers) each share one offset with two owners, the INDIR line has
# records at the 7A byte and the target, the include and part 2 are mapped, every seeded line resolves,
# and the seed names exactly the lines legK.txt halts on (looked up in the sources, not assumed).
function Test-DbgkitMaps([string]$g, [string]$seed = (Join-Path $ApScripts 'legK.seed.txt')) {
    $why = New-Object Collections.Generic.List[string]
    $ex = New-Object Collections.Generic.List[string]
    $m1 = Read-Dsm (Join-Path $g 'GAME.DSM'); $m2 = Read-Dsm (Join-Path $g 'GAME2.DSM')
    $src = [IO.File]::ReadAllLines((Join-Path $g 'DBGKIT.DSF'))
    $main = Get-DsmFile $m1 'DBGKIT.DSF'
    if ($main -lt 0) { $why.Add('GAME.DSM has no DBGKIT.DSF file record'); return [pscustomobject]@{ Reasons = $why; Excerpt = $ex } }
    $goA = Find-SrcLine $src '^> GO A '; $goB = Find-SrcLine $src '^> GO B '
    $seeA = Find-SrcLine $src '^> SEE A\s*$'; $seeB = Find-SrcLine $src '^> SEE B '
    $indir = Find-SrcLine $src 'LET 100 @101'
    foreach ($pair in @(@('GO', $goA, $goB, $false), @('SEE', $seeA, $seeB, $true))) {
        $s = Find-SharedOffset $m1 $main @($pair[1], $pair[2])
        if (-not $s) { $why.Add("$($pair[0]) A / $($pair[0]) B: no offset with records owned by both entries (headers on lines $($pair[1]), $($pair[2]))"); continue }
        foreach ($h in $pair[1], $pair[2]) { $ex.Add($m1.Entries[$s.Owners[$h]].Raw) }
        foreach ($r in $s.Recs) { $ex.Add($r.Raw) }
        $la = @($s.Recs | Where-Object { $_.Entry -eq $s.Owners[$pair[1]] })[0].Line
        $lb = @($s.Recs | Where-Object { $_.Entry -eq $s.Owners[$pair[2]] })[0].Line
        if ($pair[3] -and $la -ne $lb) { $why.Add("SEE synonym records at {0:X4} give lines $la and $lb, want one shared line" -f $s.Off) }
        if (-not $pair[3] -and ($la -ne $pair[1] -or $lb -ne $pair[2])) { $why.Add("GO records at {0:X4} give lines $la and $lb, want $($pair[1]) and $($pair[2])" -f $s.Off) }
    }
    $ir = @($m1.Conds | Where-Object { $_.File -eq $main -and $_.Line -eq $indir })
    foreach ($r in $ir) { $ex.Add($r.Raw) }
    if ($ir.Count -ne 2 -or $ir[1].Off - $ir[0].Off -ne 2 -or $ir[0].Entry -ne $ir[1].Entry) { $why.Add("INDIR line $indir`: want two records 2 bytes apart in one entry, got $($ir.Count)") }
    $inc = Get-DsmFile $m1 'inc/SHARED.DSF'
    if ($inc -lt 0 -or -not @($m1.Conds | Where-Object { $_.File -eq $inc }).Count) { $why.Add('GAME.DSM maps no condact of inc/SHARED.DSF') }
    $p2 = Get-DsmFile $m2 'PART2/PART2.DSF'
    # Part 2's GO B shares part 1's GO B line number, so only the path keeps that breakpoint out of part 2.
    $p2go = Find-SrcLine ([IO.File]::ReadAllLines((Join-Path $g 'PART2\PART2.DSF'))) '^> GO B '
    if ($p2 -lt 0 -or -not @($m2.Conds | Where-Object { $_.File -eq $p2 -and $_.Line -eq $p2go }).Count) { $why.Add("GAME2.DSM maps no condact on line $p2go of PART2/PART2.DSF") }
    if ($p2go -ne $goB) { $why.Add("PART2.DSF GO B is on line $p2go, want $goB (part 1's GO B line)") }
    $hit2 = Find-SrcLine ([IO.File]::ReadAllLines((Join-Path $g 'inc\SHARED.DSF'))) '^> HIT '
    $ping = Find-SrcLine ([IO.File]::ReadAllLines((Join-Path $g 'PART2\PART2.DSF'))) '^> PING '
    $wantSeed = @("DBGKIT.DSF $goB", "DBGKIT.DSF $seeB", "DBGKIT.DSF $indir", "inc/SHARED.DSF $hit2", "PART2/PART2.DSF $ping")
    $gotSeed = New-Object Collections.Generic.List[string]
    foreach ($l in [IO.File]::ReadAllLines($seed)) {
        if ($l -notmatch "^bp`tSourceLine`t\d`t([^`t]+)`t(\d+)`t") { continue }
        $path = $Matches[1]; $line = [int]$Matches[2]; $hit = $false
        $gotSeed.Add("$path $line")
        foreach ($m in $m1, $m2) { $fi = Get-DsmFile $m $path; if ($fi -ge 0 -and @($m.Conds | Where-Object { $_.File -eq $fi -and $_.Line -eq $line }).Count) { $hit = $true } }
        if (-not $hit) { $why.Add("seed line $line of $path has no condact in either map") }
    }
    if (($gotSeed -join ', ') -cne ($wantSeed -join ', ')) { $why.Add("seed lines are '$($gotSeed -join ', ')', the sources give '$($wantSeed -join ', ')'") }
    return [pscustomobject]@{ Reasons = $why; Excerpt = $ex }
}

function Add-Check($list, [string]$name, [bool]$ok, [string]$detail = '') {
    $list.Add([pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail })
}

# Staging checks after lib\debug.ps1 -NoLaunch ($dbg): plugin installed into $csDir, maps and SYM
# beside the sources, RELEASE\DBGKIT as BUILD.BAT left it ($before), the printed variable and launch line.
function Test-LegKStaging([string]$kit, [string]$g, [string]$csDir, [string]$before, $dbg) {
    $c = New-Object Collections.Generic.List[object]
    $out = $dbg.Lines -join "`n"
    Add-Check $c 'k-debug-exit' ($dbg.Rc -eq 0) "exit $($dbg.Rc): $out"
    $dst = Join-Path $csDir 'NextDAADDebug.dll'
    Add-Check $c 'k-plugin-installed-text' ($dbg.Lines -contains "  debugger plugin -> $dst") $out
    $same = (Test-Path -LiteralPath $dst) -and [Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($dst), [IO.File]::ReadAllBytes((Join-Path $kit 'lib\NextDAADDebug.dll')))
    Add-Check $c 'k-plugin-installed-bytes' $same $dst
    foreach ($n in 'GAME.DSM', 'GAME2.DSM') { Add-Check $c "k-map-$n" (Test-Path -LiteralPath (Join-Path $g $n)) (Join-Path $g $n) }
    $sym = Join-Path $g 'NEXTDAAD.SYM'
    Add-Check $c 'k-sym-kit-copy' ((Test-Path -LiteralPath $sym) -and [Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($sym), [IO.File]::ReadAllBytes((Join-Path $kit 'NEXTDAAD.SYM')))) $sym
    $after = Get-KitTree (Join-Path $kit 'RELEASE\DBGKIT')
    Add-Check $c 'k-release-unchanged' ($before -and $after -eq $before) "before: $before / after: $after"
    Add-Check $c 'k-release-no-maps' (-not ($after -split '\|' | Where-Object { $_ -match '\.DSM$|NEXTDAAD\.SYM$|DEBUGGER' })) $after
    $l = Get-KitLaunch $dbg.Lines $csDir
    Add-Check $c 'k-env-printed' ($l.Debug -eq $g) "NEXTDAAD_DEBUG=$($l.Debug)"
    Add-Check $c 'k-launch-printed' ($null -ne $l.Args) $out
    Add-Check $c 'k-no-mono-warning' (-not ($out -like '*CSpect under mono*')) $out
    if ((Test-Path -LiteralPath (Join-Path $g 'GAME.DSM')) -and (Test-Path -LiteralPath (Join-Path $g 'GAME2.DSM'))) {
        $t = Test-DbgkitMaps $g
        Add-Check $c 'k-maps-fixture' ($t.Reasons.Count -eq 0) ($t.Reasons -join '; ')
    }
    return [pscustomobject]@{ Checks = $c; Launch = $l }
}

# NEXTDAAD_DEBUG and the launch arguments from debug.ps1 -NoLaunch; Args is $null unless the
# printed program is $csDir\CSpect.exe. The line joins with spaces and a game name may hold one:
# flags, then -mmc=<card root ending in a separator>, then the NEX.
function Get-KitLaunch([string[]]$lines, [string]$csDir) {
    $dbgv = $null; $argv = $null
    $exe = Join-Path $csDir 'CSpect.exe'
    foreach ($x in $lines) {
        if ($x -match '^NEXTDAAD_DEBUG=(.+)$') { $dbgv = $Matches[1] }
        elseif ($x.StartsWith("launch: $exe ") -and $x.Substring("launch: $exe ".Length) -match '^((?:-(?!mmc=)\S+ )*)(-mmc=.*[\\/]) (\S.*)$') {
            $argv = @(@($Matches[1] -split ' ' | Where-Object { $_ }) + $Matches[2] + $Matches[3])
        }
    }
    return [pscustomobject]@{ Debug = $dbgv; Args = $argv }
}

# A FAIL/PASS row from named checks; failing checks become failure lines.
function New-CheckRecord([string]$leg, [string]$part, [object[]]$checks, [string]$dir) {
    $bad = @($checks | Where-Object { -not $_.Ok })
    $i = 0
    $fails = @(foreach ($k in $checks) { $i++; if (-not $k.Ok) { [pscustomobject]@{ Step = $i; Line = '-'; Raw = $k.Name; Expected = 'true'; Actual = $k.Detail } } })
    $n = $checks.Count
    return [pscustomobject]@{ Leg = $leg; Part = $part; Status = $(if ($n -and -not $bad.Count) { 'PASS' } else { 'FAIL' }); Steps = $n; Pass = $n - $bad.Count; Fail = $bad.Count; Skipped = 0
        Note = "DONE failures=$($bad.Count)"; Fails = $fails; Facts = @(); Dir = $dir }
}

# Stage leg K, check the kit's own path, then launch what debug.ps1 printed (-sound added, as on
# every leg) with the Autopilot plugin build swapped in: the kit ships the Release build.
function Invoke-LegK([string[]]$scripts, [int]$seconds) {
    $dir = Join-Path $ApRoot 'K'
    $cs = Join-Path $dir 'cspect'
    $kit = Join-Path $dir 'kit'
    $c = New-Object Collections.Generic.List[object]
    $st = $null
    try {
        Reset-StageFolder $dir $ApRoot
        Copy-CSpect $LegTable['K'].CSpect $cs
        Add-Check $c 'k-cspect-has-no-plugin' (-not (Test-Path -LiteralPath (Join-Path $cs 'NextDAADDebug.dll'))) $cs
        $g = New-LegKKit $kit $dir $cs
        $b = Invoke-KitScript $kit 'build.ps1'
        [IO.File]::WriteAllLines((Join-Path $dir 'build.txt'), [string[]]$b.Lines)
        Add-Check $c 'k-build-exit' ($b.Rc -eq 0) ($b.Lines -join "`n")
        $before = Get-KitTree (Join-Path $kit 'RELEASE\DBGKIT')
        $dbg = Invoke-KitScript $kit 'debug.ps1' @('-NoLaunch')
        [IO.File]::WriteAllLines((Join-Path $dir 'debug-nolaunch.txt'), [string[]]$dbg.Lines)
        $st = Test-LegKStaging $kit $g $cs $before $dbg
        foreach ($k in $st.Checks) { $c.Add($k) }
    }
    catch { Add-Check $c 'k-staging' $false $_.Exception.Message }
    $recs = @(New-CheckRecord 'K' 'kit staging' $c $dir)
    $recs[0] | Add-Member -NotePropertyName Files -NotePropertyValue 'build.txt, debug-nolaunch.txt, kit\'
    if ($recs[0].Status -ne 'PASS') { Write-Host "leg K staging failed: $(($recs[0].Fails | ForEach-Object { $_.Raw }) -join ', ')"; return $recs }
    # The swapped-in build must be the version the kit ships, or the walk tests other code.
    $kv = [Reflection.AssemblyName]::GetAssemblyName((Join-Path $kit 'lib\NextDAADDebug.dll')).Version
    $av = [Reflection.AssemblyName]::GetAssemblyName("$ApBin\Autopilot\net48\NextDAADDebug.dll").Version
    if ($kv -ne $av) {
        $recs = @(New-CheckRecord 'K' 'kit staging' (@($c) + @([pscustomobject]@{ Name = 'k-autopilot-version'; Ok = $false; Detail = "kit $kv, autopilot build $av - rebuild the kit with build.ps1 -Kit" })) $dir)
        Write-Host "leg K staging failed: kit plugin $kv, autopilot build $av"; return $recs
    }
    Copy-Item "$ApBin\Autopilot\net48\NextDAADDebug.dll" $cs -Force
    Assert-AutopilotDll "$cs\NextDAADDebug.dll"
    $a = @($st.Launch.Args)
    $csArgs = @($a[0..($a.Count - 2)]) + '-sound' + $a[-1]
    return $recs + @(Invoke-LegParts 'K' $dir $g $kit $csArgs $scripts $seconds)
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
    if ($vmHome -notmatch '^/[A-Za-z0-9._/-]*$') { throw "Linux leg refused: VM home missing or has unexpected characters" }
    $vmHome = $vmHome.TrimEnd('/')
    $remote = $(if ($s.remoteDir.StartsWith('~/')) { $vmHome + $s.remoteDir.Substring(1) } else { $s.remoteDir }).TrimEnd('/')
    # Never the home folder, an ancestor of it, or ~/nextdaad (the VM toolchain) and below.
    $nd = "$vmHome/nextdaad"
    if ("$vmHome/".StartsWith("$remote/") -or $remote -eq $nd -or $remote.StartsWith("$nd/")) { throw "Linux leg refused: remoteDir must be a dedicated folder, not the home folder, an ancestor of it, or ~/nextdaad and below" }
    try { $vm = "$(Invoke-Ssh $s 'sha256sum ~/nextdaad/tools/CSpect/CSpect.exe')".Trim() } catch { throw "Linux leg refused: no CSpect.exe in ~/nextdaad/tools/CSpect on the VM" }
    $win = (Get-FileHash -LiteralPath $localExe -Algorithm SHA256).Hash
    if (($vm -split '\s+')[0] -ne $win) { throw $ApHashRefusal }
    return [pscustomobject]@{ Settings = $s; Remote = $remote }
}

function New-RefusedRecord([string]$msg) {
    return [pscustomobject]@{ Leg = 'Linux'; Part = '-'; Status = 'FAIL'; Steps = 0; Pass = 0; Fail = 0; Skipped = 0; Note = $msg; Fails = @(); Facts = @(); Dir = '' }
}

# Records from the pulled-back parts\<i>-<name>\ (status.txt: exit=<rc>, 124 = timeout bound);
# step counts come from the Linux script variants in $scriptsDir.
function Get-LinuxRecords([string]$partsDir, [string[]]$names, [string]$scriptsDir) {
    $recs = @(); $i = 0
    foreach ($n in $names) {
        $i++
        $pd = Join-Path $partsDir ("$i-" + [IO.Path]::GetFileNameWithoutExtension($n))
        $st = Read-Shared (Join-Path $pd 'status.txt')
        $timedOut = $st -and $st -match 'exit=(124|137)\b'
        $sc = Join-Path $scriptsDir $n
        $want = if (Test-Path -LiteralPath $sc) { Get-ScriptStepCount $sc } else { -1 }
        $recs += New-PartRecord 'Linux' $n (Join-Path $pd 'autopilot-result.txt') $pd ([bool]$timedOut) $want
    }
    return $recs
}

# Linux variant of a script: drops "# windows-only" .. "# end windows-only" blocks and
# un-comments "# linux: <line>" lines (the window cannot close under mono).
# Unbalanced markers throw: a lost end marker would silently drop the rest of the script.
function Convert-LinuxScript([string]$src, [string]$dest) {
    $out = New-Object Collections.Generic.List[string]
    $skip = $false; $n = 0
    foreach ($l in ([IO.File]::ReadAllText($src, [Text.Encoding]::UTF8) -split "`r?`n")) {
        $n++
        if ($l -cmatch '^\s*#\s*windows-only\s*$') {
            if ($skip) { throw "windows-only marker opened twice (line $n of $src)" }
            $skip = $true; continue
        }
        if ($l -cmatch '^\s*#\s*end windows-only\s*$') {
            if (-not $skip) { throw "windows-only marker end without start (line $n of $src)" }
            $skip = $false; continue
        }
        if ($skip) { continue }
        if ($l -cmatch '^\s*#\s*linux:\s?(.*)$') { $out.Add($Matches[1]); continue }
        $out.Add($l)
    }
    if ($skip) { throw "windows-only marker not closed by end of $src" }
    [IO.File]::WriteAllText($dest, ($out -join "`n"), (New-Object Text.UTF8Encoding($false)))
}

# Preflight result or refusal record, so a refusal shows before the minutes-long build.
function Get-LinuxPreflightOrRefusal {
    try { return Get-LinuxPreflight $ApSettings (Join-Path $ApCs40 'CSpect.exe') }
    catch { Write-Host $_.Exception.Message; return New-RefusedRecord $_.Exception.Message }
}

# Upload set in $st: sd\ (leg A card), scripts\ (Linux variants), the DLL, linux-leg.sh.
function New-LinuxStage([string]$st, [string[]]$scripts) {
    New-Item -ItemType Directory -Force "$st\sd", "$st\scripts" | Out-Null
    Copy-LegGame 'A' "$st\sd" "$ApRepo\build\nextdaad.nex" "$ApRepo\build\NEXTDAAD.SYM" $ApDebugSym
    # CSpect 4.0 under mono: with DATA\GAME.DDB only the Release NEX stops at E1 (measured 2026-10-25);
    # its boot falls back to the launch folder, so a root copy is added.
    Copy-Item "$st\sd\DATA\GAME.DDB" "$st\sd\GAME.DDB"
    Copy-Item "$ApBin\Autopilot\net48\NextDAADDebug.dll" $st
    Assert-AutopilotDll "$st\NextDAADDebug.dll"
    foreach ($p in $scripts) { Convert-LinuxScript $p (Join-Path "$st\scripts" (Split-Path $p -Leaf)) }
    # LF only: a CRLF checkout of the script would not run under bash.
    $sh = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'linux-leg.sh')) -replace "`r", ''
    [IO.File]::WriteAllText("$st\linux-leg.sh", $sh, (New-Object Text.UTF8Encoding($false)))
}

# Any setup failure becomes one refused FAIL row so the other legs still reach report.md.
function Invoke-LinuxLeg([int]$seconds, $pf) {
    if ($pf.PSObject.Properties['Status']) { return @($pf) }
    $sc = Get-LegScripts 'A' @()
    if ($sc.Missing.Count) { return @(New-RefusedRecord "no script yet: $($sc.Missing -join ', ')") }
    $dir = Join-Path $ApRoot 'Linux'
    $st = Join-Path $dir 'stage'
    $names = @($sc.Parts | ForEach-Object { Split-Path $_ -Leaf })
    try {
        Reset-StageFolder $dir $ApRoot
        New-LinuxStage $st $sc.Parts
    }
    catch { Write-Host "Linux leg setup failed: $($_.Exception.Message)"; return @(New-RefusedRecord "Linux leg setup failed: $($_.Exception.Message)") }
    $s = $pf.Settings
    $tgt = "$($s.user)@$($s.host)"
    $run = "$($pf.Remote)/legA"
    $sh = "bash '$($pf.Remote)/linux-leg.sh'"
    $setupError = $null
    Push-Location $st
    try {
        Invoke-Ssh $s "mkdir -p '$($pf.Remote)'" | Out-Null
        Invoke-Scp $s @('linux-leg.sh') "${tgt}:$($pf.Remote)/"
        Invoke-Ssh $s "$sh reset '$run'" | Out-Host
        Invoke-Scp $s @('sd', 'scripts', 'NextDAADDebug.dll') "${tgt}:$run/"
        try { Invoke-Ssh $s "$sh run '$run' $seconds $($names -join ' ')" | Out-Host }
        catch { Write-Host "Linux run: $($_.Exception.Message)" }
    }
    catch { $setupError = $_.Exception.Message }
    finally {
        try { Invoke-Ssh $s "$sh kill '$run'" | Out-Host } catch { Write-Host "Linux kill: $($_.Exception.Message)" }
        Pop-Location
    }
    if ($setupError) { Write-Host "Linux leg setup failed: $setupError"; return @(New-RefusedRecord "Linux leg setup failed: $setupError") }
    try { Invoke-Scp $s @("${tgt}:$run/parts") $dir } catch { Write-Host "Linux results: $($_.Exception.Message)" }
    return Get-LinuxRecords (Join-Path $dir 'parts') $names "$st\scripts"
}

function Save-AutopilotReport($parts, $skips, $legC, [string[]]$used, [string]$stamp) {
    $md = New-AutopilotReport $parts $skips $legC (Get-Glance $used) $stamp
    New-Item -ItemType Directory -Force $ApRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $ApRoot 'report.md'), $md, (New-Object Text.UTF8Encoding($false)))
    return $md
}

if ($MyInvocation.InvocationName -eq '.') { return }

$legs = switch ($Leg) {
    'All' { 'A', 'C', 'D', 'E', 'K', 'Linux' }
    { $_ -in 'A', 'C', 'D', 'E', 'K', 'Linux' } { $Leg }
    default { throw "-Leg must be A, C, D, E, K, Linux or All (got '$Leg')" }
}
if ($ScriptOverride.Count -and ($legs.Count -ne 1 -or $legs -notin 'A', 'D', 'E', 'K')) { throw '-ScriptOverride needs exactly one of -Leg A, D, E or K' }

$parts = @(); $skips = @(); $legC = @(); $used = @()
if ($legs -contains 'K' -or $legs -contains 'Linux') { $skips += [pscustomobject]@{ Leg = 'K (Linux)'; Reason = $LegKLinuxReason } }
$linuxPf = if ($legs -contains 'Linux') { Get-LinuxPreflightOrRefusal } else { $null }
$linuxRuns = $linuxPf -and -not $linuxPf.PSObject.Properties['Status']
# A refused Linux-only run has nothing to build; leg K needs only the plugin (the kit has its own NEX).
if (@($legs | Where-Object { $_ -ne 'Linux' }).Count -or $linuxRuns) {
    $proj = Join-Path $ApRepo 'cspect-plugin\NextDAADDebug.csproj'
    foreach ($cfg in 'Release', 'Autopilot') {
        & dotnet build $proj -c $cfg "-p:CSpectDir=$ApCs40" | Out-Host
        if ($LASTEXITCODE) { throw "plugin $cfg build failed" }
    }
    New-Item -ItemType Directory -Force $ApRoot | Out-Null
}
if (@($legs | Where-Object { $_ -in 'A', 'C', 'D', 'E' }).Count -or $linuxRuns) {
    # DEBUG first for leg E's mismatched SYM, then Release for the staged NEX and SYM (stage-legs.ps1 order).
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ApRepo 'build.ps1') | Out-Host
    if ($LASTEXITCODE) { throw 'build.ps1 (DEBUG) failed' }
    Copy-Item (Join-Path $ApRepo 'build\NEXTDAAD.SYM') $ApDebugSym -Force
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ApRepo 'build.ps1') -Release | Out-Host
    if ($LASTEXITCODE) { throw 'build.ps1 -Release failed' }
}
foreach ($l in $legs) {
    if ($l -eq 'Linux') {
        $sc = Get-LegScripts 'A' @()
        if (-not $sc.Missing.Count) { $used += $sc.Parts }
        $parts += Invoke-LinuxLeg $TimeoutSeconds $linuxPf
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
    $parts += if ($l -eq 'K') { Invoke-LegK $sc.Parts $TimeoutSeconds } else { Invoke-ScriptLeg $l $sc.Parts $TimeoutSeconds }
}
$stamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ', commit ' + (& git -C $ApRepo rev-parse --short HEAD)
$md = Save-AutopilotReport $parts $skips $legC $used $stamp
$report = Join-Path $ApRoot 'report.md'
$md
"report: $report"
if ($md -match '(?m)^Overall: FAIL') { exit 1 }
