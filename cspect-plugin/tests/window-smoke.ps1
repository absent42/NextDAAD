# Boots DBGFIX with the window enabled for 12 s and checks debugger.log:
# the window opened, nothing was disarmed or disabled. Needs build.ps1 first.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
& "$repo\cspect-plugin\stage-cspect.ps1" | Out-Host
$leg = Join-Path $repo 'tests\out\dbgwin'
if (Test-Path -LiteralPath $leg) { Remove-Item -LiteralPath $leg -Recurse -Force }
New-Item -ItemType Directory -Force $leg | Out-Null
Copy-Item "$PSScriptRoot\fixtures\DBGFIX.DDB" "$leg\GAME.DDB"
Copy-Item "$PSScriptRoot\fixtures\DBGFIX.DSM" "$leg\GAME.DSM"
Copy-Item "$PSScriptRoot\fixtures\DBGFIX.DSF" $leg
Copy-Item "$repo\build\nextdaad.nex" $leg
Copy-Item "$repo\build\NEXTDAAD.SYM" $leg
$env:NEXTDAAD_DEBUG = $leg
try {
    $p = Start-Process -FilePath "$repo\build\cspect-dbg\CSpect.exe" -ArgumentList '-w1', '-zxnext', '-esc', '-sound', "-mmc=$leg\", "$leg\nextdaad.nex" -WorkingDirectory $leg -PassThru
    Start-Sleep -Seconds 12
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
}
finally { Remove-Item Env:NEXTDAAD_DEBUG -ErrorAction SilentlyContinue }
$log = Get-Content "$leg\debugger.log" -Raw
if ($log -notmatch 'window opened 800x640') { throw "window did not open:`n$log" }
if ($log -match 'disarmed|window disabled') { throw "plugin failed:`n$log" }
if (-not (Test-Path "$leg\DEBUGGER.local.TXT")) { throw 'settings file not written' }
'window-smoke: window opened, no failures'
