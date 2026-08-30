# build.ps1 - assembles all.asm into GAME.XBN in this directory.
# Requires sjasmplus on PATH: https://github.com/z00m128/sjasmplus
$ErrorActionPreference = 'Stop'
$sjasmplus = Get-Command sjasmplus.exe -ErrorAction SilentlyContinue
if (-not $sjasmplus) {
    Write-Error "sjasmplus.exe not found on PATH. Install sjasmplus (https://github.com/z00m128/sjasmplus) and add it to PATH before running this script."
    exit 1
}
$kitRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Push-Location $PSScriptRoot
try {
    & $sjasmplus.Source --msg=war -I "$kitRoot" all.asm
    if ($LASTEXITCODE -ne 0) { throw "all.asm assembly failed" }
}
finally {
    Pop-Location
}
Write-Output "GAME.XBN written to $PSScriptRoot"
