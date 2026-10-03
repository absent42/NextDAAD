# Boots DBGFIX in a private CSpect with the plugin in trace mode (no window,
# no breakpoints) and compares the condact sequence with DBGFIX.trace.
# Needs build.ps1 first (build\nextdaad.nex + build\NEXTDAAD.SYM).
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
& "$repo\cspect-plugin\stage-cspect.ps1" | Out-Host
$leg = Join-Path $repo 'tests\out\dbgtrace'
if (Test-Path -LiteralPath $leg) { Remove-Item -LiteralPath $leg -Recurse -Force }
New-Item -ItemType Directory -Force $leg | Out-Null
Copy-Item "$PSScriptRoot\fixtures\DBGFIX.DDB" "$leg\GAME.DDB"
Copy-Item "$repo\build\nextdaad.nex" $leg
Copy-Item "$repo\build\NEXTDAAD.SYM" $leg
$trace = Join-Path $leg 'trace.txt'
$env:NEXTDAAD_DEBUG = $leg
$env:NEXTDAAD_DEBUG_TRACE = $trace
$env:NEXTDAAD_DEBUG_NOWINDOW = '1'
try {
    $p = Start-Process -FilePath "$repo\build\cspect-dbg\CSpect.exe" -ArgumentList '-w1', '-zxnext', '-esc', '-sound', "-mmc=$leg\", "$leg\nextdaad.nex" -WorkingDirectory $leg -PassThru
    Start-Sleep -Seconds 10
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
}
finally { Remove-Item Env:NEXTDAAD_DEBUG, Env:NEXTDAAD_DEBUG_TRACE, Env:NEXTDAAD_DEBUG_NOWINDOW -ErrorAction SilentlyContinue }
if (-not (Test-Path -LiteralPath $trace)) { throw "no trace written - plugin not loaded? see $leg\debugger.log" }
$got = @(Get-Content $trace | ForEach-Object { ($_ -split ' ', 4)[3] })
$want = @(Get-Content "$PSScriptRoot\fixtures\DBGFIX.trace")
if ($got.Count -lt $want.Count) { throw "trace has $($got.Count) lines, expected at least $($want.Count):`n$($got -join "`n")" }
for ($i = 0; $i -lt $want.Count; $i++) {
    if ($got[$i] -ne $want[$i]) { throw "trace line $($i + 1): got '$($got[$i])', want '$($want[$i])'" }
}
"trace-test: $($want.Count) condacts match"
