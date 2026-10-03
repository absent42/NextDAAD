# Builds the plugin and stages a private CSpect copy with it. The source
# CSpect folder is only read; the copy lives under build\ (gitignored).
# Disk images (*.mmc) are not copied.
param([string]$CSpectDir = 'D:\ZXNextDev\cspect', [string]$Dest = '', [switch]$Fresh)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
if (-not $Dest) { $Dest = Join-Path $repo 'build\cspect-dbg' }
& dotnet build (Join-Path $PSScriptRoot 'NextDAADDebug.csproj') -c Release "-p:CSpectDir=$CSpectDir" | Out-Host
if ($LASTEXITCODE) { throw 'plugin build failed' }
if ($Fresh) {
    $sep = [string][IO.Path]::DirectorySeparatorChar
    $root = [IO.Path]::GetFullPath((Join-Path $repo 'build')).TrimEnd($sep) + $sep
    $full = [IO.Path]::GetFullPath($Dest).TrimEnd($sep) + $sep
    if ($full -eq $root -or -not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "-Fresh refused: $Dest is not under $root" }
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
}
if (-not (Test-Path -LiteralPath (Join-Path $Dest 'CSpect.exe'))) {
    New-Item -ItemType Directory -Force $Dest | Out-Null
    & robocopy $CSpectDir $Dest /E /XF *.mmc /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
}
Copy-Item (Join-Path $repo 'build\cspect-plugin\bin\NextDAADDebug\Release\net452\NextDAADDebug.dll') $Dest -Force
"staged $Dest"
