# Selftest for run-autopilot.ps1: staging refusal, DLL marker check, report
# generation, the leg C checker and leg K staging (DBGKIT compiled in a scratch
# kit by lib\debug.ps1 -NoLaunch against a stand-in CSpect). No CSpect launch.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$PSScriptRoot\run-autopilot.ps1"

$work = Join-Path $repo 'build\autopilot-selftest'
$script:fails = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "PASS $name" } else { $script:fails++; "FAIL $name $detail" }
}
function Throws([scriptblock]$b) {
    try { & $b; return $null } catch { return $_.Exception.Message }
}

$buildRoot = Join-Path $repo 'build'
if (Test-Path -LiteralPath $work) {
    if (-not (Test-Path -LiteralPath (Join-Path $work $StageMarker))) { throw "refusing: $work has no $StageMarker" }
    Remove-StagedTree $work $buildRoot
}
New-Item -ItemType Directory -Force $work | Out-Null
Set-Content -LiteralPath (Join-Path $work $StageMarker) -Value 'selftest'

# (a) staging into a folder without the marker throws, and leaves it alone
$foreign = Join-Path $work 'foreign'
New-Item -ItemType Directory -Force $foreign | Out-Null
Set-Content -LiteralPath "$foreign\keep.txt" -Value 'x'
$m = Throws { Reset-StageFolder $foreign $work }
Check 'a-unmarked-refused' ($m -like 'refusing:*') $m
Check 'a-unmarked-untouched' (Test-Path -LiteralPath "$foreign\keep.txt")
$m = Throws { Reset-StageFolder (Join-Path $repo 'sd\LEGX') $work }
Check 'a-outside-root-refused' ($m -like 'refusing:*') $m
$ok = Join-Path $work 'marked'
Reset-StageFolder $ok $work
Set-Content -LiteralPath "$ok\old.txt" -Value 'x'
Reset-StageFolder $ok $work
Check 'a-marked-replaced' ((Test-Path -LiteralPath (Join-Path $ok $StageMarker)) -and -not (Test-Path -LiteralPath "$ok\old.txt"))
# A junction inside a marked folder is refused; its target (also under $work) is untouched.
$jt = Join-Path $work 'jtarget'
New-Item -ItemType Directory -Force $jt | Out-Null
Set-Content -LiteralPath "$jt\keep.txt" -Value 'x'
$jdir = Join-Path $work 'jmarked'
Reset-StageFolder $jdir $work
New-Item -ItemType Junction -Path "$jdir\link" -Target $jt | Out-Null
$m = Throws { Reset-StageFolder $jdir $work }
Check 'a-junction-refused' ($m -like 'refusing:*reparse point*') $m
$m = Throws { Remove-StagedTree "$jdir\link" $work }
Check 'a-junction-itself-refused' ($m -like 'refusing:*reparse point*') $m
Check 'a-junction-target-untouched' (Test-Path -LiteralPath "$jt\keep.txt")
[IO.Directory]::Delete("$jdir\link", $false)
Check 'a-junction-removed-link-only' ((Test-Path -LiteralPath "$jt\keep.txt") -and -not (Test-Path -LiteralPath "$jdir\link"))

# (b) a Release DLL is refused; one carrying the marker (UTF-16, as in the #US heap) is accepted
$rel = Join-Path $work 'release.dll'
[IO.File]::WriteAllBytes($rel, [Text.Encoding]::ASCII.GetBytes('MZ plain release build'))
$m = Throws { Assert-AutopilotDll $rel }
Check 'b-release-refused' ($m -like 'staged DLL is not an autopilot build*') $m
$ap = Join-Path $work 'autopilot.dll'
[IO.File]::WriteAllBytes($ap, [Text.Encoding]::ASCII.GetBytes('MZ ') + [Text.Encoding]::Unicode.GetBytes($AutopilotMarker))
Check 'b-autopilot-accepted' ($null -eq (Throws { Assert-AutopilotDll $ap }))
# Real build outputs, when present.
foreach ($cfg in 'Release', 'Autopilot') {
    $d = Join-Path $repo "build\cspect-plugin\bin\NextDAADDebug\$cfg\net48\NextDAADDebug.dll"
    if (-not (Test-Path -LiteralPath $d)) { "skip b-real-$cfg (not built)"; continue }
    $m = Throws { Assert-AutopilotDll $d }
    Check "b-real-$cfg" ($(if ($cfg -eq 'Release') { $m -like 'staged DLL is not an autopilot build*' } else { $null -eq $m })) $m
}

# (c) report from canned results
$r1 = Join-Path $work 'r1.txt'
[IO.File]::WriteAllLines($r1, [string[]]@(
    'STEP 1 PASS line 2 | wait status "HALTED" | expected status contains "HALTED" within 10s | actual HALTED',
    'STEP 2 FAIL line 3 | click " Step " | expected " Step " on screen | actual not found',
    'STEP 3 SKIPPED line 4 | quit | expected - | actual not run',
    'FACT halted-state=1',
    'FACT step-ms=40',
    'DONE failures=1'))
$r2 = Join-Path $work 'r2.txt'
[IO.File]::WriteAllLines($r2, [string[]]@('STEP 1 PASS line 1 | hotkey r | expected - | actual '))
New-Item -ItemType Directory -Force "$work\A1\dumps" | Out-Null
Set-Content -LiteralPath "$work\A1\dumps\002.txt" -Value 'dump'
$parts = @(
    (New-PartRecord 'A' 'legA-1.txt' $r1 (Join-Path $work 'A1') $false 3),
    (New-PartRecord 'A' 'legA-2.txt' $r2 (Join-Path $work 'A2') $true 1),
    (New-PartRecord 'D' 'legD.txt' (Join-Path $work 'none.txt') (Join-Path $work 'D1') $false 1))
$skips = @([pscustomobject]@{ Leg = 'E'; Reason = 'no script yet: legE.txt' })
$legC = [pscustomobject]@{ Leg = 'C'; Pass = $false; Reasons = @('trace.txt first line: got "x", want "y"'); Folder = 'C:\c' }
$md = New-AutopilotReport $parts $skips @($legC) @('drag the window and relaunch') 'TESTSTAMP'
$lines = $md -split "`r?`n"
Check 'c-total-A1' ($lines -contains '| A | legA-1.txt | FAIL | 3 | 1 | 1 | 1 | DONE failures=1 |') ($lines -join '/')
Check 'c-total-A2' ($lines -contains '| A | legA-2.txt | FAIL | 1 | 1 | 0 | 0 | no DONE line (timed out) |')
Check 'c-total-D' ($lines -contains '| D | legD.txt | FAIL | 0 | 0 | 0 | 0 | no result file |')
Check 'c-skip-E' ($lines -contains '| E | - | SKIPPED | 0 | 0 | 0 | 0 | no script yet: legE.txt |')
Check 'c-fail-line' ($lines -contains '- A legA-1.txt STEP 2 line 3: `click " Step "` - expected " Step " on screen - actual not found')
Check 'c-fail-dump' ($lines -contains ('  dump: ' + (Join-Path $work 'A1\dumps\002.txt')))
Check 'c-fail-nodone' ($lines -contains '- A legA-2.txt: no DONE line (timed out)')
Check 'c-fact-1' ($lines -contains '| A | legA-1.txt | halted-state | 1 |')
Check 'c-fact-2' ($lines -contains '| A | legA-1.txt | step-ms | 40 |')
Check 'c-legC' ($lines -contains '| C | - | FAIL | 0 | 0 | 0 | 0 | trace.txt first line: got "x", want "y" |')
Check 'c-glance' ($lines -contains '- drag the window and relaunch')
Check 'c-overall' ($lines -contains 'Overall: FAIL (4 failing parts)')
# Clean PASS, skipped legs beside it, nothing ran, and the step-count gate.
$rp = Join-Path $work 'rpass.txt'
[IO.File]::WriteAllLines($rp, [string[]]@(
    'STEP 1 PASS line 2 | note "a" | expected - | actual a',
    'STEP 2 PASS line 3 | quit | expected - | actual ',
    'DONE failures=0'))
$pass = New-PartRecord 'A' 'smoke.txt' $rp (Join-Path $work 'P1') $false 2
$l2 = (New-AutopilotReport @($pass) $skips @() @() 'T') -split "`r?`n"
Check 'c-clean-pass-row' ($l2 -contains '| A | smoke.txt | PASS | 2 | 2 | 0 | 0 | DONE failures=0 |') ($l2 -join '/')
Check 'c-skipped-not-failure' ($l2 -contains 'Overall: PASS') ($l2 -join '/')
$l2 = (New-AutopilotReport @() $skips @() @() 'T') -split "`r?`n"
Check 'c-nothing-ran' ($l2 -contains 'Overall: FAIL (nothing ran)') ($l2 -join '/')
$l2 = (New-AutopilotReport @() @() @() @() 'T') -split "`r?`n"
Check 'c-empty-run' ($l2 -contains 'Overall: FAIL (nothing ran)') ($l2 -join '/')
$rf = Join-Path $work 'rfail0.txt'
[IO.File]::WriteAllLines($rf, [string[]]@(
    'STEP 1 FAIL line 2 | expect running | expected debugger running | actual debugger state 1',
    'DONE failures=0'))
$rec = New-PartRecord 'A' 'x.txt' $rf (Join-Path $work 'X1') $false 1
Check 'c-done0-with-fail-line' ($rec.Status -eq 'FAIL' -and $rec.Fail -eq 1) "$($rec.Status) $($rec.Note)"
$rz = Join-Path $work 'rzero.txt'
[IO.File]::WriteAllLines($rz, [string[]]@('DONE failures=0'))
$rec = New-PartRecord 'A' 'x.txt' $rz (Join-Path $work 'X1') $false 5
Check 'c-zero-steps' ($rec.Status -eq 'FAIL' -and $rec.Note -like 'no steps reported*') "$($rec.Status) $($rec.Note)"
$rec = New-PartRecord 'A' 'x.txt' $rp (Join-Path $work 'X1') $false 528
Check 'c-step-mismatch' ($rec.Status -eq 'FAIL' -and $rec.Note -eq 'steps: 2 reported, script has 528 (DONE failures=0)') "$($rec.Status) $($rec.Note)"
$rec = New-PartRecord 'A' 'x.txt' $rp (Join-Path $work 'X1') $false
Check 'c-step-count-unknown' ($rec.Status -eq 'FAIL' -and $rec.Note -like 'steps: 2 reported, script has unknown*') "$($rec.Status) $($rec.Note)"
$l2 = (New-AutopilotReport @($rec) @() @() @() 'T') -split "`r?`n"
Check 'c-step-mismatch-listed' ($l2 -contains '- A x.txt: steps: 2 reported, script has unknown (DONE failures=0)') ($l2 -join '/')
$l2 = (New-AutopilotReport @((New-PartRecord 'A' 'legA-1.txt' $r1 (Join-Path $work 'NoDumps') $false 3)) @() @() @() 'T') -split "`r?`n"
Check 'c-dump-not-written' ($l2 -contains '  dump: none written') ($l2 -join '/')
$sc = Join-Path $work 'count.txt'
[IO.File]::WriteAllLines($sc, [string[]]@('# c', '', '   ', 'note "a # b"', '  # indented comment', '  quit  # trailing'))
Check 'c-step-count' ((Get-ScriptStepCount $sc) -eq 2) (Get-ScriptStepCount $sc)
# The runner's count agrees with ScriptParser in the Autopilot DLL for every shipped script,
# Windows and Linux-converted variants.
$apDll = Join-Path $repo 'build\cspect-plugin\bin\NextDAADDebug\Autopilot\net48\NextDAADDebug.dll'
Check 'c-autopilot-dll-present' (Test-Path -LiteralPath $apDll) "build -c Autopilot first: $apDll"
if (Test-Path -LiteralPath $apDll) {
    $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($apDll))
    $parser = $asm.GetType('NextDAADDebug.Autopilot.ScriptParser')
    foreach ($p in Get-ChildItem -LiteralPath $ApScripts -Filter '*.txt' | Where-Object { $_.Name -notlike '*.seed.txt' -and $_.Name -notlike '*.expect.txt' -and $_.Name -notlike '*.intro.txt' }) {
        $lin = Join-Path $work ('real-linux-' + $p.Name)
        Convert-LinuxScript $p.FullName $lin
        foreach ($v in @(@('', $p.FullName), @('linux ', $lin))) {
            $n = $parser.GetMethod('Parse').Invoke($null, @([IO.File]::ReadAllText($v[1]))).Count
            Check "c-step-count-real $($v[0])$($p.Name)" ((Get-ScriptStepCount $v[1]) -eq $n) "$(Get-ScriptStepCount $v[1]) vs $n"
        }
    }
}

# (d) leg C checker on canned logs
$tooOld = Get-TooOldText
Check 'd-tooold-read' ($tooOld -like 'NextDAAD debugger needs CSpect 4.0*') $tooOld
$exp = Join-Path $work 'expect.txt'
[IO.File]::WriteAllLines($exp, [string[]]@('# comment', 'P0 E0422 C03F8 LET 100 7'))
$log = Join-Path $work 'debugger.log'
$tr = Join-Path $work 'trace.txt'
[IO.File]::WriteAllLines($log, [string[]]@('2026-10-25 01:00:00 NextDAAD debugger 0.1.0.0', "2026-10-25 01:00:00 $tooOld"))
[IO.File]::WriteAllLines($tr, [string[]]@('P0 E0422 C03F8 LET 100 7', 'P0 E0422 C03FB LET @100 3'))
$c = Test-LegC $log $tr $exp $tooOld
Check 'd-pass' ($c.Pass) ($c.Reasons -join '; ')
[IO.File]::WriteAllLines($tr, [string[]]@('P0 E0422 C03FB LET @100 3'))
$c = Test-LegC $log $tr $exp $tooOld
Check 'd-wrong-trace' ((-not $c.Pass) -and ($c.Reasons -join ';') -like '*trace.txt first line*')
[IO.File]::WriteAllLines($tr, [string[]]@('P0 E0422 C03F8 LET 100 7'))
[IO.File]::WriteAllLines($log, [string[]]@('2026-10-25 01:00:00 window opened 800x672'))
$c = Test-LegC $log $tr $exp $tooOld
Check 'd-no-tooold' ((-not $c.Pass) -and ($c.Reasons -join ';') -like '*TooOld*')
$c = Test-LegC (Join-Path $work 'nolog.txt') (Join-Path $work 'notrace.txt') $exp $tooOld
Check 'd-missing-files' ((-not $c.Pass) -and $c.Reasons.Count -eq 2)
[IO.File]::WriteAllLines($tr, [string[]]@('p0 e0422 c03f8 let 100 7'))
$c = Test-LegC $log $tr $exp $tooOld
Check 'd-trace-case-sensitive' ((-not $c.Pass) -and ($c.Reasons -join ';') -like '*trace.txt first line*') ($c.Reasons -join ';')
$pfc = Join-Path $work 'PlatformFacts.cs'
[IO.File]::WriteAllText($pfc, 'public const string TooOld = "";')
$m = Throws { Get-TooOldText $pfc }
Check 'd-tooold-empty-refused' ($m -like 'VersionGate.TooOld not found*') $m
# Leg C version gate: stand-in CSpect.exe assemblies at 4.0.0.0 and 3.4.1.0, and none at all.
foreach ($v in '4.0.0.0', '3.4.1.0') {
    $vd = Join-Path $work "cs-$v"
    New-Item -ItemType Directory -Force $vd | Out-Null
    $cls = 'V' + ($v -replace '\.', '_')
    Add-Type -TypeDefinition "[assembly: System.Reflection.AssemblyVersion(`"$v`")] public class $cls {}" -OutputAssembly "$vd\stand-in.dll" -OutputType Library
    Move-Item -LiteralPath "$vd\stand-in.dll" "$vd\CSpect.exe"      # a .exe output would need Main
}
$m = Get-LegCVersionRefusal (Join-Path $work 'cs-4.0.0.0')
Check 'd-legc-40-refused' ($m -eq 'leg C needs a CSpect older than 4.0 - found 4.0.0.0') $m
$m = Get-LegCVersionRefusal (Join-Path $work 'cs-3.4.1.0')
Check 'd-legc-341-accepted' ($null -eq $m) $m
$m = Get-LegCVersionRefusal (Join-Path $work 'cs-none')
Check 'd-legc-missing-refused' ($m -like 'leg C needs a CSpect older than 4.0 - cannot read*') $m
$l2 = (New-AutopilotReport @() @() @([pscustomobject]@{ Leg = 'C'; Pass = $false; Reasons = @('leg C needs a CSpect older than 4.0 - found 4.0.0.0'); Folder = $null }) @() 'T') -split "`r?`n"
Check 'd-legc-refusal-row' ($l2 -contains '| C | - | FAIL | 0 | 0 | 0 | 0 | leg C needs a CSpect older than 4.0 - found 4.0.0.0 |' -and $l2 -contains 'Overall: FAIL (1 failing parts)') ($l2 -join '/')
# The real folders, when present: leg C's is below 4.0, the 4.0 one is refused.
if (Test-Path -LiteralPath "$ApCsOld\CSpect.exe") { $m = Get-LegCVersionRefusal $ApCsOld; Check 'd-legc-real-old-accepted' ($null -eq $m) $m } else { "skip d-legc-real-old-accepted (no $ApCsOld)" }
if (Test-Path -LiteralPath "$ApCs40\CSpect.exe") { $m = Get-LegCVersionRefusal $ApCs40; Check 'd-legc-real-40-refused' ($m -like '*found 4.*') $m } else { "skip d-legc-real-40-refused (no $ApCs40)" }

# Invoke-CSpect restores the caller's NEXTDAAD_DEBUG* variables (a stand-in exe that exits at once).
$fcs = Join-Path $work 'fakecs'
New-Item -ItemType Directory -Force $fcs | Out-Null
Copy-Item (Join-Path $env:SystemRoot 'System32\whoami.exe') "$fcs\CSpect.exe"
$env:NEXTDAAD_DEBUG = 'owner-folder'; Remove-Item Env:NEXTDAAD_DEBUG_TRACE -ErrorAction SilentlyContinue
$r = Invoke-CSpect $fcs $work @('/?') @{ NEXTDAAD_DEBUG = 'leg-folder'; NEXTDAAD_DEBUG_TRACE = 'leg-trace' } 10 (Join-Path $work 'fake-stdout.txt') { $false } @()
Check 'e-env-restored' ($env:NEXTDAAD_DEBUG -eq 'owner-folder' -and $null -eq $env:NEXTDAAD_DEBUG_TRACE) "$env:NEXTDAAD_DEBUG / $env:NEXTDAAD_DEBUG_TRACE"
Check 'e-fake-exited' ($r.ExitedSelf) ($r | Out-String)
Remove-Item Env:NEXTDAAD_DEBUG -ErrorAction SilentlyContinue

# script table: missing scripts skip a leg
$miss = Get-LegScripts 'A' $null (Join-Path $work 'noscripts')
Check 'e-missing-script' ($miss.Missing.Count -gt 0)
$sm = Get-LegScripts 'A' @("$PSScriptRoot\scripts\smoke.txt") (Join-Path $work 'noscripts')
Check 'e-override' ($sm.Missing.Count -eq 0 -and $sm.Parts.Count -eq 1)

# (f) per-leg game files: D stale DSM CRC, E DEBUG SYM and no seed, A unchanged
$fsrc = Join-Path $work 'fsrc'
New-Item -ItemType Directory -Force $fsrc | Out-Null
[IO.File]::WriteAllText("$fsrc\nextdaad.nex", 'NEX')
[IO.File]::WriteAllLines("$fsrc\rel.sym", [string[]]@("NEXTDAAD-SYM`t1", "build`tabc1234`tRelease"))
[IO.File]::WriteAllLines("$fsrc\dbg.sym", [string[]]@("NEXTDAAD-SYM`t1", "build`tabc1234`tDEBUG"))
$fxDsm = [IO.File]::ReadAllText("$repo\cspect-plugin\tests\fixtures\DBGFIX.DSM")
foreach ($l in 'A', 'D', 'E') {
    $g = Join-Path $work "game$l"
    New-Item -ItemType Directory -Force $g | Out-Null
    Copy-LegGame $l $g "$fsrc\nextdaad.nex" "$fsrc\rel.sym" "$fsrc\dbg.sym"
}
$dD = [IO.File]::ReadAllText("$work\gameD\GAME.DSM")
Check 'f-D-crc-zero' ($dD -match "(?m)^ddb`t00000000`t") (($dD -split "`n")[1])
Check 'f-D-rest-same' (($dD -replace "(?m)^ddb`t[0-9A-Fa-f]+`t", '') -eq ($fxDsm -replace "(?m)^ddb`t[0-9A-Fa-f]+`t", ''))
Check 'f-D-seed' (Test-Path -LiteralPath "$work\gameD\DEBUGGER.local.TXT")
Check 'f-E-sym-debug' ((Get-Content "$work\gameE\NEXTDAAD.SYM")[1] -match "^build`t\S+`tDEBUG$")
Check 'f-E-no-seed' (-not (Test-Path -LiteralPath "$work\gameE\DEBUGGER.local.TXT"))
Check 'f-A-dsm-same' ([IO.File]::ReadAllText("$work\gameA\GAME.DSM") -eq $fxDsm)
Check 'f-A-sym-release' ((Get-Content "$work\gameA\NEXTDAAD.SYM")[1] -match 'Release$')
Check 'f-A-seed' (Test-Path -LiteralPath "$work\gameA\DEBUGGER.local.TXT")
Check 'f-A-ddb-in-data' (Test-Path -LiteralPath "$work\gameA\DATA\GAME.DDB")

# (i) leg K: scratch kit only in a folder it marked, DBGKIT built by lib\debug.ps1 -NoLaunch
$kr = Join-Path $work 'K'
Reset-StageFolder $kr $work
$kcs = Join-Path $kr 'cspect'
New-Item -ItemType Directory -Force $kcs | Out-Null
Add-Type -TypeDefinition '[assembly: System.Reflection.AssemblyVersion("4.0.0.0")] public class KStandIn40 {}' -OutputAssembly "$kcs\stand-in.dll" -OutputType Library
Move-Item -LiteralPath "$kcs\stand-in.dll" "$kcs\CSpect.exe"
$kf = Join-Path $kr 'foreign'
New-Item -ItemType Directory -Force $kf | Out-Null
Set-Content -LiteralPath "$kf\keep.txt" -Value 'x'
$m = Throws { New-LegKKit $kf $kr $kcs }
Check 'i-kit-unmarked-refused' ($m -like 'refusing:*') $m
Check 'i-kit-unmarked-untouched' (@(Get-ChildItem -LiteralPath $kf -Force).Count -eq 1 -and (Test-Path -LiteralPath "$kf\keep.txt"))
$m = Throws { New-LegKKit $ApKitSrc $ApRepo $kcs }
Check 'i-kit-repo-tree-refused' ($m -like 'refusing:*') $m
$m = Throws { New-LegKKit (Join-Path $repo 'build\autopilot-elsewhere\kit') $kr $kcs }
Check 'i-kit-outside-root-refused' ($m -like 'refusing:*' -and -not (Test-Path -LiteralPath (Join-Path $repo 'build\autopilot-elsewhere'))) $m
Set-Content -LiteralPath "$kr\src.txt" -Value 'x'
$m = Throws { Copy-ListedFiles $kr (Join-Path $kr 'cl') @('src.txt', '..\escape.txt') }
Check 'i-copy-escape-refused' ($m -like 'refusing:*' -and -not (Test-Path -LiteralPath "$kr\escape.txt")) $m
function Get-Snapshot([string]$d) {
    if (-not (Test-Path -LiteralPath $d)) { return '' }
    return (@(Get-ChildItem -LiteralPath $d -Recurse -File -Force | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join "`n")
}
$kitSnap = Get-Snapshot $ApKitSrc; $csSnap = Get-Snapshot $ApCs40
$kk = Join-Path $kr 'kit'
$kg = New-LegKKit $kk $kr $kcs
Check 'i-kit-marked' (Test-Path -LiteralPath (Join-Path $kk $StageMarker))
Check 'i-kit-no-plugin-yet' (-not (Test-Path -LiteralPath "$kcs\NextDAADDebug.dll"))
$kb = Invoke-KitScript $kk 'build.ps1'
Check 'i-kit-build' ($kb.Rc -eq 0) ($kb.Lines -join '/')
$krel = Get-KitTree (Join-Path $kk 'RELEASE\DBGKIT')
$kd = Invoke-KitScript $kk 'debug.ps1' @('-NoLaunch')
$kst = Test-LegKStaging $kk $kg $kcs $krel $kd
foreach ($k in $kst.Checks) { Check "i-$($k.Name)" $k.Ok $k.Detail }
Check 'i-launch-args' (($kst.Launch.Args -join ' ') -ceq '-w3 -zxnext -esc -mmc=RELEASE\DBGKIT\ RELEASE\DBGKIT\DBGKIT.NEX') ($kst.Launch.Args -join ' ')
# Two owners at one offset, read straight from GAME.DSM: entry records give the two header lines.
$dsm = [IO.File]::ReadAllLines("$kg\GAME.DSM")
$src = [IO.File]::ReadAllLines("$kg\DBGKIT.DSF")
$hdr = @{}; for ($i = 0; $i -lt $src.Count; $i++) { if ($src[$i] -match '^> (GO|SEE) ([AB])\b') { $hdr["$($Matches[1]) $($Matches[2])"] = $i + 1 } }
$ent = @{}; foreach ($l in $dsm) { if ($l -match "^entry`t([0-9A-F]{4})`t0`t(\d+)$") { $ent[$Matches[1]] = [int]$Matches[2] } }
$own = @{}; foreach ($l in $dsm) { if ($l -match "^cond`t([0-9A-F]{4})`t([0-9A-F]{4})`t") { $own[$Matches[1]] = @($own[$Matches[1]]) + $Matches[2] } }
$pairs = @(foreach ($o in $own.Keys) { $u = @($own[$o] | Where-Object { $_ } | Select-Object -Unique); if ($u.Count -ge 2) { (@($u | ForEach-Object { $ent[$_] }) | Sort-Object) -join ',' } })
Check 'i-dsm-synonym-two-owners' ($pairs -contains "$($hdr['SEE A']),$($hdr['SEE B'])") "SEE $($hdr['SEE A']),$($hdr['SEE B']) in: $($pairs -join ' ')"
Check 'i-dsm-go-two-owners' ($pairs -contains "$($hdr['GO A']),$($hdr['GO B'])") "GO $($hdr['GO A']),$($hdr['GO B']) in: $($pairs -join ' ')"
$t = Test-DbgkitMaps $kg
Check 'i-dsm-fixture' ($t.Reasons.Count -eq 0) ($t.Reasons -join '; ')
# A seed line that resolves but is not the one legK.txt halts on fails.
$badSeed = Join-Path $kr 'bad.seed.txt'
[IO.File]::WriteAllText($badSeed, ([IO.File]::ReadAllText((Join-Path $ApScripts 'legK.seed.txt')) -replace "DBGKIT\.DSF`t112`t", "DBGKIT.DSF`t110`t"))
$t = Test-DbgkitMaps $kg $badSeed
Check 'i-dsm-seed-line-moved-fails' (($t.Reasons -join ';') -like "*seed lines are 'DBGKIT.DSF 110,*") ($t.Reasons -join '; ')
# Launch lines whose card root and NEX name hold spaces keep each argument whole.
$sp = Get-KitLaunch @("launch: $kcs\CSpect.exe -w3 -zxnext -esc -mmc=RELEASE\My Game\\ RELEASE\My Game\My Game.NEX") "$kcs\CSpect.exe"
Check 'i-launch-spaced' (($sp.Args.Count -eq 5) -and $sp.Args[3] -ceq '-mmc=RELEASE\My Game\\' -and $sp.Args[4] -ceq 'RELEASE\My Game\My Game.NEX') ($sp.Args -join '|')
$sp = Get-KitLaunch @("launch: $kcs\CSpect.exe -w3 -zxnext -esc RELEASE\G\G.NEX") "$kcs\CSpect.exe"
Check 'i-launch-no-mmc-refused' ($null -eq $sp.Args) ($sp.Args -join '|')
$sp = Get-KitLaunch @('launch: mono /h/legK/cspect/CSpect.exe -w3 -zxnext -esc -mmc=RELEASE/DBGKIT// RELEASE/DBGKIT/DBGKIT.NEX') 'mono /h/legK/cspect/CSpect.exe'
Check 'i-launch-linux' (($sp.Args -join '|') -ceq '-w3|-zxnext|-esc|-mmc=RELEASE/DBGKIT//|RELEASE/DBGKIT/DBGKIT.NEX') ($sp.Args -join '|')
# The kit plugin gate compares bytes, not the version.
$gk = Join-Path $kr 'gate'
New-Item -ItemType Directory -Force $gk | Out-Null
$kitDllSrc = Join-Path $ApKitSrc 'lib\NextDAADDebug.dll'
Copy-Item $kitDllSrc "$gk\rel.dll"
Check 'i-gate-same-bytes' ($null -eq (Get-KitPluginRefusal $kitDllSrc "$gk\rel.dll"))
[IO.File]::WriteAllBytes("$gk\rel.dll", [byte[]]([IO.File]::ReadAllBytes($kitDllSrc) + [byte[]](0)))
$m = Get-KitPluginRefusal $kitDllSrc "$gk\rel.dll"
Check 'i-gate-same-version-other-bytes' ($m -like 'kit plugin * is not this tree''s Release build (*) - rebuild the kit with build.ps1 -Kit') $m
$m = Get-KitPluginRefusal $kitDllSrc "$gk\none.dll"
Check 'i-gate-no-release-build' ($m -like 'no Release plugin build at *') $m
# The checker fails a map with one INDIR record dropped, or with GO B's shared records dropped.
$kn = Join-Path $kr 'neg'
Copy-Item -LiteralPath $kg $kn -Recurse
$ir = @($dsm | Where-Object { $_ -match "^cond`t[0-9A-F]{4}`t[0-9A-F]{4}`t0`t119`t" })
[IO.File]::WriteAllLines("$kn\GAME.DSM", [string[]]@($dsm | Where-Object { $_ -ne $ir[-1] }))
$t = Test-DbgkitMaps $kn
Check 'i-dsm-indir-dropped-fails' (($t.Reasons -join ';') -like '*INDIR line 119*') ($t.Reasons -join '; ')
$gb = @($ent.Keys | Where-Object { $ent[$_] -eq $hdr['GO B'] })[0]
[IO.File]::WriteAllLines("$kn\GAME.DSM", [string[]]@($dsm | Where-Object { $_ -notmatch "^cond`t[0-9A-F]{4}`t$gb`t" }))
$t = Test-DbgkitMaps $kn
Check 'i-dsm-go-share-dropped-fails' (($t.Reasons -join ';') -like '*GO A / GO B*') ($t.Reasons -join '; ')
Check 'i-no-write-authoring-kit' ((Get-Snapshot $ApKitSrc) -ceq $kitSnap)
Check 'i-no-write-cspect-source' ((Get-Snapshot $ApCs40) -ceq $csSnap)
$kr2 = (New-CheckRecord 'K' 'kit staging' @([pscustomobject]@{ Name = 'k-a'; Ok = $true; Detail = '' }, [pscustomobject]@{ Name = 'k-b'; Ok = $false; Detail = 'why' }) $kr)
Check 'i-check-record-fail' ($kr2.Status -eq 'FAIL' -and $kr2.Steps -eq 2 -and $kr2.Fail -eq 1 -and $kr2.Fails[0].Raw -eq 'k-b' -and $kr2.Fails[0].Step -eq 2) ($kr2 | Out-String)
$kr2 | Add-Member -NotePropertyName Files -NotePropertyValue 'build.txt, debug-nolaunch.txt, kit\'
$l2 = (New-AutopilotReport @($kr2) @() @() @() 'T') -split "`r?`n"
Check 'i-check-record-rows' ($l2 -contains '| K | kit staging | FAIL | 2 | 1 | 1 | 0 | DONE failures=1 |' -and $l2 -contains '- K kit staging STEP 2 line -: `k-b` - expected true - actual why' -and $l2 -contains "- K kit staging: $kr (build.txt, debug-nolaunch.txt, kit\)") ($l2 -join '/')

# (g0) Linux staging: leg A's card holds DATA\GAME.DDB only; linux-leg.sh doubles the card-root separator.
$lst = Join-Path $work 'lstage'
if ((Test-Path -LiteralPath "$repo\build\nextdaad.nex") -and (Test-Path -LiteralPath $apDll)) {
    New-LinuxStage $lst (Get-LegScripts 'A' @()).Parts
    Check 'g-linux-stage-data-ddb' (Test-Path -LiteralPath "$lst\sd\DATA\GAME.DDB")
    Check 'g-linux-stage-no-root-ddb' (-not (Test-Path -LiteralPath "$lst\sd\GAME.DDB"))
    Check 'g-linux-stage-script-lf' (-not ([IO.File]::ReadAllText("$lst\linux-leg.sh")).Contains("`r"))
} else { 'skip g-linux-stage-* (build\nextdaad.nex or the Autopilot DLL not built)' }
$lsh = [IO.File]::ReadAllText("$PSScriptRoot\linux-leg.sh")
Check 'g-linux-launch-doubled-root' ($lsh.Contains('"-mmc=$LEG//"') -and -not $lsh.Contains('"-mmc=$LEG/"')) 'linux-leg.sh run launch'

# (g) Linux leg: settings refusals, hash gate, canned results, script variant. ssh is stubbed.
$script:sshCalls = @()
$script:vmHash = ''
$script:sshMode = 'ok'
function Invoke-Ssh($s, [string]$cmd) {
    $script:sshCalls += $cmd
    if ($cmd -eq 'true') { if ($script:sshMode -eq 'unreach') { throw 'ssh exit 255 for: true' }; return }
    if ($cmd -like 'mkdir -p *' -or $cmd -like "* kill '*") { return }
    if ($cmd -like "* reset '*") { throw 'ssh exit 2 for: reset' }
    if ($cmd -like 'echo $HOME*') { return '/home/placeholder' }
    if ($cmd -like 'sha256sum *') { return "$($script:vmHash)  /home/placeholder/nextdaad/tools/CSpect/CSpect.exe" }
    throw "unexpected ssh command: $cmd"
}
$exe = Join-Path $work 'CSpect.exe'
[IO.File]::WriteAllText($exe, 'fake cspect')
$m = Throws { Get-LinuxPreflight (Join-Path $work 'nosettings.json') $exe }
Check 'g-missing-refused' ($m -like 'Linux leg refused: *missing*') $m
Check 'g-missing-no-ssh' ($script:sshCalls.Count -eq 0) ($script:sshCalls -join ';')
$bad = Join-Path $work 'bad.json'
[IO.File]::WriteAllText($bad, '{"host": "vm-host", "user": ')
$m = Throws { Get-LinuxPreflight $bad $exe }
Check 'g-malformed-refused' ($m -like 'Linux leg refused: *not valid JSON*') $m
[IO.File]::WriteAllText($bad, '{"host": "vm-host", "remoteDir": "~/x"}')
$m = Throws { Get-LinuxPreflight $bad $exe }
Check 'g-field-missing-refused' ($m -like 'Linux leg refused: *user*') $m
[IO.File]::WriteAllText($bad, '{"host": "vm-host", "user": "someone", "remoteDir": "~/x y"}')
$m = Throws { Get-LinuxPreflight $bad $exe }
Check 'g-remotedir-refused' ($m -like 'Linux leg refused: *remoteDir*') $m
Check 'g-malformed-no-ssh' ($script:sshCalls.Count -eq 0) ($script:sshCalls -join ';')
$good = Join-Path $work 'good.json'
[IO.File]::WriteAllText($good, '{"host": "vm-host", "user": "someone", "remoteDir": "~/autopilot-dir"}')
$script:vmHash = '00' * 32
$m = Throws { Get-LinuxPreflight $good $exe }
Check 'g-hash-mismatch-exact' ($m -ceq "the VM's CSpect differs from Windows - update it first") $m
$script:vmHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLower()
$m = Throws { $script:pf = Get-LinuxPreflight $good $exe }
Check 'g-hash-match' ($null -eq $m -and $script:pf.Remote -eq '/home/placeholder/autopilot-dir') "$m $($script:pf.Remote)"
$ref = New-RefusedRecord "the VM's CSpect differs from Windows - update it first"
$lp = Join-Path $work 'lparts'
New-Item -ItemType Directory -Force "$lp\1-legA-1", "$lp\2-legA-2" | Out-Null
Copy-Item $r1 "$lp\1-legA-1\autopilot-result.txt"
Set-Content -LiteralPath "$lp\1-legA-1\status.txt" -Value 'exit=0 ms=61000'
Set-Content -LiteralPath "$lp\2-legA-2\status.txt" -Value 'exit=124 ms=120000'
$lsd = Join-Path $work 'lscripts'
New-Item -ItemType Directory -Force $lsd | Out-Null
[IO.File]::WriteAllLines("$lsd\legA-1.txt", [string[]]@('# x', 'note "a"', 'note "b"', 'quit'))
$lrec = @(Get-LinuxRecords $lp @('legA-1.txt', 'legA-2.txt') $lsd)
$md3 = New-AutopilotReport ($parts + $lrec + @($ref)) @() @() @() 'T'
$l3 = $md3 -split "`r?`n"
Check 'g-linux-total-1' ($l3 -contains '| Linux | legA-1.txt | FAIL | 3 | 1 | 1 | 1 | DONE failures=1 |') ($l3 -join '/')
Check 'g-linux-total-2' ($l3 -contains '| Linux | legA-2.txt | FAIL | 0 | 0 | 0 | 0 | no result file (timed out) |')
Check 'g-linux-refused' ($l3 -contains "| Linux | - | FAIL | 0 | 0 | 0 | 0 | the VM's CSpect differs from Windows - update it first |")
Check 'g-linux-fact' ($l3 -contains '| Linux | legA-1.txt | step-ms | 40 |')
Check 'g-linux-fail-line' ($l3 -contains '- Linux legA-1.txt STEP 2 line 3: `click " Step "` - expected " Step " on screen - actual not found')
Check 'g-linux-overall' ($l3 -contains 'Overall: FAIL (6 failing parts)')
$ls = Join-Path $work 'lsrc.txt'
$ae = [string][char]0xC4
[IO.File]::WriteAllText($ls, "a`n# windows-only`nhotkey a`n# end windows-only`n# linux: expect log `"x`"`nb $ae`n", (New-Object Text.UTF8Encoding($false)))
$ld = Join-Path $work 'ldst.txt'
Convert-LinuxScript $ls $ld
Check 'g-linux-script' ([IO.File]::ReadAllText($ld) -ceq "a`nexpect log `"x`"`nb $ae`n") ([IO.File]::ReadAllText($ld))
$real = Join-Path $work 'legA-1.linux.txt'
Convert-LinuxScript "$PSScriptRoot\scripts\legA-1.txt" $real
$rt = [IO.File]::ReadAllText($real)
Check 'g-legA1-no-double-toggle' (-not ($rt -match "(?m)^hotkey a\nhotkey a$") -and $rt -match '(?m)^expect log "window cannot be closed under mono')

# (h) Linux leg hardening: unreachable and bad host, remoteDir placement, markers, setup failure
$script:sshCalls = @(); $script:sshMode = 'unreach'
$m = Throws { Get-LinuxPreflight $good $exe }
Check 'h-unreachable-refused' ($m -like 'Linux leg refused: VM unreachable*') $m
Check 'h-unreachable-one-ssh' ($script:sshCalls.Count -eq 1) ($script:sshCalls -join ';')
$script:sshCalls = @(); $script:sshMode = 'ok'
[IO.File]::WriteAllText($bad, '{"host": "vm host;x", "user": "someone", "remoteDir": "~/x"}')
$m = Throws { Get-LinuxPreflight $bad $exe }
Check 'h-bad-host-refused' ($m -like 'Linux leg refused: host or user*') $m
Check 'h-bad-host-no-ssh' ($script:sshCalls.Count -eq 0) ($script:sshCalls -join ';')
foreach ($rd in '/home/placeholder', '/home', '~/nextdaad', '~/nextdaad/tools/CSpect', '~/nextdaad/x') {
    $script:sshCalls = @()
    [IO.File]::WriteAllText($bad, "{`"host`": `"vm-host`", `"user`": `"someone`", `"remoteDir`": `"$rd`"}")
    $m = Throws { Get-LinuxPreflight $bad $exe }
    Check "h-remotedir-placement $rd" ("$m" -like 'Linux leg refused: remoteDir must be a dedicated folder*') $m
    Check "h-remotedir-no-write $rd" (@($script:sshCalls | Where-Object { $_ -notin 'true', 'echo $HOME' -and $_ -notlike 'sha256sum *' }).Count -eq 0) ($script:sshCalls -join ';')
}
[IO.File]::WriteAllText($bad, '{"host": "vm-host", "user": "someone", "remoteDir": "~/nextdaad-autopilot"}')
Check 'h-remotedir-sibling-ok' ($null -eq (Throws { $null = Get-LinuxPreflight $bad $exe }))
foreach ($case in @("a`n# windows-only`nb`n", "# windows-only`n# windows-only`n# end windows-only`n", "# end windows-only`n")) {
    [IO.File]::WriteAllText($ls, $case)
    $m = Throws { Convert-LinuxScript $ls $ld }
    Check "h-marker-refused $(($case -split "`n")[0..1] -join '/')" ("$m" -like 'windows-only marker*') $m
}
$gb = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
if (Test-Path -LiteralPath $gb) {
    $oldHome = $env:HOME; $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        # Unguarded, these would write only under $work (POSIX form for Git bash).
        $ph = '/' + $work.Substring(0, 1).ToLower() + ($work.Substring(2) -replace '\\', '/') + '/fakehome'
        $env:HOME = $ph
        $o = & $gb "$PSScriptRoot\linux-leg.sh" reset "$ph/nextdaad/tools/CSpect/legA" 2>&1 | Out-String
        Check 'h-sh-run-under-src-refused' ($LASTEXITCODE -eq 2 -and $o -like '*refusing*') "$LASTEXITCODE $o"
        $o = & $gb "$PSScriptRoot\linux-leg.sh" kill "$ph/nextdaad/tools/x" 2>&1 | Out-String
        Check 'h-sh-run-under-tools-refused' ($LASTEXITCODE -eq 2 -and $o -like '*refusing*') "$LASTEXITCODE $o"
    }
    finally { $env:HOME = $oldHome; $ErrorActionPreference = $oldEap; $global:LASTEXITCODE = 0 }
}
else { 'skip h-sh-* (no Git bash)' }
# Setup failure (reset refused on the VM) is a refused FAIL row; the report still carries other legs.
$ApRoot = $work
$script:sshCalls = @(); $script:scpCalls = @()
function Invoke-Scp($s, [string[]]$from, [string]$to) { $script:scpCalls += "$($from -join ' ') -> $to" }
function New-LinuxStage([string]$st, [string[]]$scripts) { New-Item -ItemType Directory -Force $st | Out-Null }
$pfOk = [pscustomobject]@{ Settings = [pscustomobject]@{ host = 'vm-host'; user = 'someone'; remoteDir = '~/autopilot-dir' }; Remote = '/home/placeholder/autopilot-dir' }
$lr = @(Invoke-LinuxLeg 30 $pfOk)
Check 'h-setup-failure-row' ($lr.Count -eq 1 -and $lr[0].Status -eq 'FAIL' -and $lr[0].Note -like 'Linux leg setup failed: *') (($lr | ForEach-Object { $_.Note }) -join ';')
Check 'h-setup-failure-killed' (@($script:sshCalls | Where-Object { $_ -like "* kill '*" }).Count -eq 1) ($script:sshCalls -join ';')
Check 'h-setup-failure-no-run' (@($script:sshCalls | Where-Object { $_ -like "* run '*" }).Count -eq 0)
$lr2 = @(Invoke-LinuxLeg 30 (New-RefusedRecord 'Linux leg refused: x'))
Check 'h-refused-passthrough' ($lr2.Count -eq 1 -and $lr2[0].Note -eq 'Linux leg refused: x')
$aRec = New-PartRecord 'A' 'legA-1.txt' $r1 (Join-Path $work 'A1') $false 3
$null = Save-AutopilotReport (@($aRec) + $lr) @() @() @() 'T'
$rep = [IO.File]::ReadAllText((Join-Path $work 'report.md')) -split "`r?`n"
Check 'h-report-written' (($rep -contains '| A | legA-1.txt | FAIL | 3 | 1 | 1 | 1 | DONE failures=1 |') -and @($rep | Where-Object { $_ -like '| Linux | - | FAIL |*Linux leg setup failed: *' }).Count -eq 1) ($rep -join '/')

# (j) Leg K on the VM: the Linux kit staged, facts pulled back and checked here, then one launch of
# what debug.ps1 printed. ssh and scp are stubbed; the VM's out\ is canned from the leg K build in (i).
$ApReleaseDll = Join-Path $ApKitSrc 'lib\NextDAADDebug.dll'
$runK = '/home/placeholder/autopilot-dir/legK'
$script:mmcOut = '-mmc=RELEASE/DBGKIT//'
function Invoke-Ssh($s, [string]$cmd) { $script:sshCalls += $cmd }
function Invoke-Scp($s, [string[]]$from, [string]$to) {
    $script:scpCalls += "$($from -join ' ') -> $to"
    if ($from[0] -ne "someone@vm-host:$runK/out") { return }
    $o = Join-Path $to 'out'
    New-Item -ItemType Directory -Force $o | Out-Null
    Copy-Item -LiteralPath $kg "$o\DBGKIT" -Recurse
    foreach ($n in 'build.rc', 'debug.rc') { [IO.File]::WriteAllText("$o\$n", "0`n") }
    [IO.File]::WriteAllText("$o\plugin-before.txt", "absent`n")
    [IO.File]::WriteAllText("$o\plugin-sha.txt", (Get-FileHash -LiteralPath (Join-Path $ApKitSrc 'lib\NextDAADDebug.dll') -Algorithm SHA256).Hash.ToLower() + "`n")
    foreach ($n in 'tree-before.txt', 'tree-after.txt') { [IO.File]::WriteAllText("$o\$n", "DATA/GAME.DDB|DATA/nextdaad.nex|DBGKIT.NEX`n") }
    [IO.File]::WriteAllText("$o\build.txt", "BUILD OK`n")
    [IO.File]::WriteAllText("$o\debug-nolaunch.txt", "  debugger plugin -> $runK/cspect/NextDAADDebug.dll`nNEXTDAAD_DEBUG=$runK/kit/DBGKIT`nlaunch: mono $runK/cspect/CSpect.exe -w3 -zxnext -esc $($script:mmcOut) RELEASE/DBGKIT/DBGKIT.NEX`n")
}
$script:sshCalls = @(); $script:scpCalls = @()
$kRecs = @(Invoke-LinuxLegK 30 $pfOk)
$kst = @($kRecs | Where-Object { $_.Part -eq 'kit staging' })
Check 'j-linux-k-staging-pass' ($kst.Count -eq 1 -and $kst[0].Leg -eq 'Linux K' -and $kst[0].Status -eq 'PASS') (($kRecs | ForEach-Object { "$($_.Leg) $($_.Part) $($_.Status) $($_.Note) $(($_.Fails | ForEach-Object { "$($_.Raw)=$($_.Actual)" }) -join ';')" }) -join ' / ')
Check 'j-linux-k-kit-run' (@($script:sshCalls | Where-Object { $_ -ceq "bash '/home/placeholder/autopilot-dir/linux-leg.sh' kit '$runK'" }).Count -eq 1) ($script:sshCalls -join ';')
$want = "bash '/home/placeholder/autopilot-dir/linux-leg.sh' kitrun '$runK' 30 legK.txt '-w3' '-zxnext' '-esc' '-mmc=RELEASE/DBGKIT//' '-sound' 'RELEASE/DBGKIT/DBGKIT.NEX'"
Check 'j-linux-k-launch' (@($script:sshCalls | Where-Object { $_ -ceq $want }).Count -eq 1) ($script:sshCalls -join ';')
Check 'j-linux-k-killed' (@($script:sshCalls | Where-Object { $_ -like "* kill '$runK'" }).Count -eq 1) ($script:sshCalls -join ';')
Check 'j-linux-k-part-row' (@($kRecs | Where-Object { $_.Leg -eq 'Linux K' -and $_.Part -eq 'legK.txt' }).Count -eq 1) (($kRecs | ForEach-Object { "$($_.Leg) $($_.Part)" }) -join ' / ')
$kcfg = [IO.File]::ReadAllText((Join-Path $work 'LinuxK\stage\kit\CONFIG.local.BAT'))
Check 'j-linux-k-config' ($kcfg -ceq "SET GAME=DBGKIT`nSET RUN=0`nSET EMULATOR=cspect`nSET CSPECTDIR=$runK/cspect`n") $kcfg
Check 'j-linux-k-linux-kit' ((Test-Path -LiteralPath (Join-Path $work 'LinuxK\stage\kit\debug.sh')) -and -not (Test-Path -LiteralPath (Join-Path $work 'LinuxK\stage\kit\DEBUG.BAT')))
# A single trailing separator (E1 under mono) fails staging, and nothing is launched.
$script:mmcOut = '-mmc=RELEASE/DBGKIT/'
$script:sshCalls = @()
$kRecs = @(Invoke-LinuxLegK 30 $pfOk)
Check 'j-linux-k-single-sep-fails' ($kRecs.Count -eq 1 -and $kRecs[0].Status -eq 'FAIL' -and @($kRecs[0].Fails | Where-Object { $_.Raw -eq 'k-launch-card-root' }).Count -eq 1) (($kRecs | ForEach-Object { "$($_.Part) $($_.Status)" }) -join ' / ')
Check 'j-linux-k-single-sep-no-launch' (@($script:sshCalls | Where-Object { $_ -like '* kitrun *' }).Count -eq 0) ($script:sshCalls -join ';')
$kRecs = @(Invoke-LinuxLegK 30 (New-RefusedRecord 'Linux leg refused: x'))
Check 'j-linux-k-refusal-once' ($kRecs.Count -eq 0)

Remove-StagedTree $work $buildRoot
if ($script:fails) { "selftest: $($script:fails) failing"; exit 1 }
'selftest: all pass'
