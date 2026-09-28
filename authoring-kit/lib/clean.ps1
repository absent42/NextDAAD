# clean.ps1 - empty RELEASE\ the way CLEAN.BAT did: top-level files and
# the INTRO folder. PART<n>\ folders are left, as before.
$ErrorActionPreference = 'Stop'
$rel = Join-Path (Get-Location).Path 'RELEASE'
if (Test-Path -LiteralPath $rel -PathType Container) {
    Get-ChildItem -LiteralPath $rel -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    $intro = Join-Path $rel 'INTRO'
    if (Test-Path -LiteralPath $intro) { Remove-Item -LiteralPath $intro -Recurse -Force }
    Write-Host 'cleaned RELEASE\'
} else {
    Write-Host 'nothing to clean'
}
exit 0
