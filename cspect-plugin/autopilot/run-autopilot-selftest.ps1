# Selftest for run-autopilot.ps1: staging refusal, DLL marker check, report
# generation and the leg C checker. No build, no CSpect launch.
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

if (Test-Path -LiteralPath $work) {
    if (-not (Test-Path -LiteralPath (Join-Path $work $StageMarker))) { throw "refusing: $work has no $StageMarker" }
    Remove-Item -LiteralPath $work -Recurse -Force
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
$parts = @(
    (New-PartRecord 'A' 'legA-1.txt' $r1 (Join-Path $work 'A1') $false),
    (New-PartRecord 'A' 'legA-2.txt' $r2 (Join-Path $work 'A2') $true),
    (New-PartRecord 'D' 'legD.txt' (Join-Path $work 'none.txt') (Join-Path $work 'D1') $false))
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
$md2 = New-AutopilotReport @((New-PartRecord 'A' 'smoke.txt' $r1 (Join-Path $work 'A1') $false)) @() @() @() 'T'
Check 'c-skipped-not-failure' (($md2 -split "`r?`n") -contains 'Overall: FAIL (1 failing parts)')

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

# script table: missing scripts skip a leg
$miss = Get-LegScripts 'A' $null (Join-Path $work 'noscripts')
Check 'e-missing-script' ($miss.Missing.Count -gt 0)
$sm = Get-LegScripts 'A' @("$PSScriptRoot\scripts\smoke.txt") (Join-Path $work 'noscripts')
Check 'e-override' ($sm.Missing.Count -eq 0 -and $sm.Parts.Count -eq 1)

Remove-Item -LiteralPath $work -Recurse -Force
if ($script:fails) { "selftest: $($script:fails) failing"; exit 1 }
'selftest: all pass'
