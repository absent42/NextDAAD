# debug.ps1 - build with source maps, install the debugger plugin and run CSpect
# with NEXTDAAD_DEBUG = the game source folder. Launched by DEBUG.BAT / debug.sh. cwd = kit root.
param([switch]$NoLaunch)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'kitplatform.ps1')
. (Join-Path $PSScriptRoot 'kitconfig.ps1')
. (Join-Path $PSScriptRoot 'kittools.ps1')
. (Join-Path $PSScriptRoot 'kitgame.ps1')
. (Join-Path $PSScriptRoot 'kitcspect.ps1')
$kitRoot = (Get-Location).Path
$cfg0 = Read-KitConfig $kitRoot
try { $g = Resolve-KitGame $cfg0 $kitRoot } catch { Write-Host "$($_.Exception.Message)"; exit 1 }
$cfg = Read-KitConfig $kitRoot $g.CfgFile
Export-KitConfig $cfg
$t = Resolve-KitTools $cfg $kitRoot
function abs([string]$p) { if ([IO.Path]::IsPathRooted($p)) { return $p } else { return Join-Path $kitRoot $p } }

# ---- preflight: CSpect 4.0 or later, kit files present ----
if ($t.EMULATOR -eq 'jnext') {
    $runName = if ($OnWindows) { 'RUN.BAT' } else { 'run.sh' }
    Write-Host "ERROR: the debugger runs in CSpect - set EMULATOR=cspect in CONFIG.local.BAT ($runName still runs jNext)"; exit 1
}
if ($t.EMULATOR -ne 'cspect') { Write-Host "ERROR: EMULATOR=$($t.EMULATOR) - use cspect or jnext"; exit 1 }
if (-not (Test-KitCSpect $t)) { exit 1 }
$cspDir = Split-Path -Parent $t.CSPECT
$cspAbs = abs $cspDir
$ver = $null
try { $ver = [Reflection.AssemblyName]::GetAssemblyName((abs $t.CSPECT)).Version } catch { $ver = $null }
if ($null -eq $ver) {
    # ImGui.NET.dll ships with CSpect 4.0 and not with 3.x.
    if (Test-Path -LiteralPath (Join-Path $cspAbs 'ImGui.NET.dll') -PathType Leaf) { Write-Host 'note: could not read the CSpect version - assuming 4.0 or later' }
    else { Write-Host "ERROR: could not read the CSpect version in $cspDir - the debugger needs CSpect 4.0 or later"; exit 1 }
} elseif ($ver -lt [version]'4.0') {
    Write-Host "ERROR: the debugger needs CSpect 4.0 or later - found $ver in $cspDir"; exit 1
}
$sym = Join-Path $kitRoot 'NEXTDAAD.SYM'
$dll = Join-Path $PSScriptRoot 'NextDAADDebug.dll'
foreach ($need in @($sym, $dll)) {
    if (-not (Test-Path -LiteralPath $need -PathType Leaf)) { Write-Host "ERROR: $need not found - the kit is incomplete"; exit 1 }
}

# ---- build: maps beside the sources, no RUN=1 hand-off ----
$global:LASTEXITCODE = 0
$code = 0
try { & (Join-Path $PSScriptRoot 'build.ps1') -SrcMap -NoRun | Out-Host; $code = $LASTEXITCODE } catch { Write-Host "ERROR: $($_.Exception.Message)"; $code = 1 }
if ($code -ne 0) { exit $code }

# ---- the interpreter's symbols beside the maps ----
$symOut = Join-Path $g.SrcRoot 'NEXTDAAD.SYM'
if ([IO.Path]::GetFullPath($symOut) -ne [IO.Path]::GetFullPath($sym)) {
    try { Copy-Item -LiteralPath $sym -Destination $symOut -Force }
    catch { Write-Host "ERROR: could not copy NEXTDAAD.SYM into $($g.SrcRoot)"; exit 1 }
}

# ---- plugin: install when missing, older, or the same version with other bytes ----
if (-not (Install-KitPlugin -Source $dll -Dir $cspAbs -Label $cspDir)) { exit 1 }

if (-not $OnWindows) {
    Write-Host "WARNING: CSpect under mono does not change into the game's DATA folder yet (reported to its author) - the game will stop at E1 until a fixed CSpect is released"
}
# The plugin's own test switches stay out of an author's session.
$envs = @{ NEXTDAAD_DEBUG = $g.SrcRoot }
foreach ($k in 'NEXTDAAD_DEBUG_TRACE', 'NEXTDAAD_DEBUG_NOWINDOW', 'NEXTDAAD_DEBUG_SETTINGS', 'NEXTDAAD_DEBUG_AUTOPILOT') { $envs[$k] = $null }
Start-KitCSpect -Tools $t -Game $g -Env $envs -NoLaunch:$NoLaunch
exit 0
