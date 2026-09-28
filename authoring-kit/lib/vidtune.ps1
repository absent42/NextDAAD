# vidtune.ps1 - VIDTUNE.BAT body. Prefers the shipped exe (>1MB, so an LFS
# pointer file is skipped); -Src or a missing exe falls back to Python.
param([switch]$Src)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'kitplatform.ps1')
. (Join-Path $PSScriptRoot 'kitconfig.ps1')
. (Join-Path $PSScriptRoot 'kittools.ps1')
$kitRoot = (Get-Location).Path
$cfg = Read-KitConfig $kitRoot
Export-KitConfig $cfg
$t = Resolve-KitTools $cfg $kitRoot
$env:PYTHONPATH = $PSScriptRoot + [IO.Path]::PathSeparator + $env:PYTHONPATH
$kitExe = Join-Path $kitRoot (Join-Path 'tools' (Join-Path 'vidtools' "vidtune$ExeSuffix"))
if (-not $Src) {
    foreach ($exe in @($t.VIDTUNE, $kitExe)) {
        $abs = if ([IO.Path]::IsPathRooted($exe)) { $exe } else { Join-Path $kitRoot $exe }
        if ((Test-Path -LiteralPath $abs -PathType Leaf) -and (Get-Item -LiteralPath $abs).Length -gt 1000000) {
            Start-Process -FilePath $abs -WorkingDirectory $kitRoot | Out-Null
            exit 0
        }
    }
}
$py = Find-Python @('PySide6', 'numpy', 'PIL')
if ($py) {
    $rest = @()
    if ($py.Length -gt 1) { $rest = $py[1..($py.Length - 1)] }
    Start-Process -FilePath $py[0] -ArgumentList ($rest + @('-m', 'vidtune')) -WorkingDirectory $kitRoot | Out-Null
    exit 0
}
Write-Host 'ERROR: vidtune not found. Looked for:'
Write-Host "         $($t.VIDTUNE)"
Write-Host "         $kitExe"
Write-Host '       See tools\README.txt, or set VIDTOOLSDIR in CONFIG.BAT'
Write-Host '       or Python 3 with: pip install PySide6 numpy Pillow'
exit 1
