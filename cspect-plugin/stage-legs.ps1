# Stages the debugger bench legs. Each sd\LEG* folder is complete: game,
# interpreter, SYM, source map and its own CSpect copy with the plugin.
# tools\CSpect (3.3.1) and D:\ZXNextDev\cspect (3.4.0) are only read.
# A leg folder is only ever replaced when it carries the marker this script wrote.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$fx = Join-Path $PSScriptRoot 'tests\fixtures'
$cs340 = 'D:\ZXNextDev\cspect'
$dll = Join-Path $repo 'build\cspect-plugin\bin\NextDAADDebug\Release\net452\NextDAADDebug.dll'
$marker = '.cspect-debugger-leg'
$legNames = 'LEGDBGW', 'LEGDBG331', 'LEGDBGSTALE', 'LEGDBGBADSYM'
$T = [string][char]9
$nl = [string][char]10

foreach ($n in $legNames) {
    $p = Join-Path $repo "sd\$n"
    if ((Test-Path -LiteralPath $p) -and -not (Test-Path -LiteralPath (Join-Path $p $marker))) {
        throw "refusing: $p exists and was not staged by this script (no $marker)"
    }
}

& "$repo\build.ps1" | Out-Host
$debugSym = Join-Path $repo 'build\NEXTDAAD.DEBUG.SYM'
Copy-Item "$repo\build\NEXTDAAD.SYM" $debugSym -Force
& "$repo\build.ps1" -Release | Out-Host
& "$PSScriptRoot\stage-cspect.ps1" -CSpectDir $cs340 | Out-Host        # builds the DLL against 3.4.0

# DEBUGGER.local.TXT text: bp lines are Kind, enabled, A, B, C, Op.
function Seed([string[]]$records) {
    return ('NEXTDAAD-DEBUGGER' + $T + '1' + $nl) + (($records | ForEach-Object { $_ -replace '\|', $T }) -join $nl) + $nl
}

# List order is priority when two breakpoints match one condact.
# GET = 40; DBGFIX.DSF line 121 is "SYSMESS 8".
$seedFull = Seed @(
    'bp|DebugMarker|1|0|-1|-1|Eq',
    'bp|RuntimeError|1|0|-1|-1|Eq',
    'bp|Process|1|2|21|50|Eq',
    'bp|Condact|1|40|-1|-1|Eq',
    'bp|SourceLine|1|0|121|-1|Eq',
    'bp|FlagCompare|1|38|1|-1|Eq',
    'bp|FlagChange|1|38|-1|-1|Eq',
    'bp|ObjectMoved|1|0|-1|-1|Eq',
    'watch|flag|38',
    'watch|flag|100',
    'watch|flag|7',
    'watch|object|0',
    'window|-1|-1')
$seedStale = Seed @(
    'bp|DebugMarker|1|0|-1|-1|Eq',
    'bp|RuntimeError|1|0|-1|-1|Eq',
    'bp|SourceLine|1|0|121|-1|Eq',
    'watch|flag|38',
    'window|-1|-1')

function New-Leg([string]$name, [string]$cspectSrc, [string]$seed) {
    $leg = Join-Path $repo "sd\$name"
    if (Test-Path -LiteralPath $leg) {
        if (-not (Test-Path -LiteralPath (Join-Path $leg $marker))) { throw "refusing: $leg has no $marker" }
        Remove-Item -LiteralPath $leg -Recurse -Force
    }
    New-Item -ItemType Directory -Force "$leg\cspect" | Out-Null
    Set-Content -LiteralPath (Join-Path $leg $marker) -Value 'staged by cspect-plugin\stage-legs.ps1'
    Copy-Item "$fx\DBGFIX.DDB" "$leg\GAME.DDB"
    Copy-Item "$fx\DBGFIX.DSM" "$leg\GAME.DSM"
    Copy-Item "$fx\DBGFIX.DSF" $leg
    Copy-Item "$repo\build\nextdaad.nex" $leg
    Copy-Item "$repo\build\NEXTDAAD.SYM" $leg
    & robocopy $cspectSrc "$leg\cspect" /E /XF *.mmc /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
    Copy-Item $dll "$leg\cspect" -Force
    if ($seed) { [IO.File]::WriteAllText("$leg\DEBUGGER.seed.TXT", $seed, (New-Object Text.UTF8Encoding($false))) }
    return $leg
}

New-Leg 'LEGDBGW' $cs340 $seedFull | Out-Null
New-Leg 'LEGDBG331' (Join-Path $repo 'tools\CSpect') $null | Out-Null
$stale = New-Leg 'LEGDBGSTALE' $cs340 $seedStale
$dsm = [IO.File]::ReadAllText("$stale\GAME.DSM") -replace '(?m)^ddb\t[0-9A-Fa-f]+\t', "ddb`t00000000`t"
[IO.File]::WriteAllText("$stale\GAME.DSM", $dsm, (New-Object Text.UTF8Encoding($false)))
$bad = New-Leg 'LEGDBGBADSYM' $cs340 $null
Copy-Item $debugSym "$bad\NEXTDAAD.SYM" -Force
'staged sd\LEGDBGW, sd\LEGDBG331, sd\LEGDBGSTALE, sd\LEGDBGBADSYM'
