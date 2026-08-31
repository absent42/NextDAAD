# build.ps1 - assembles timer.asm into GAME.XBN in this directory.
# Assembler resolution: -SjasmPlus, then the kit's tools\sjasmplus\, then PATH.
param([string]$SjasmPlus = '')
$ErrorActionPreference = 'Stop'
$kitRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $kitRoot 'lib\resolve-sjasmplus.ps1')
$SjasmPlus = Resolve-SjasmPlus -SjasmPlus $SjasmPlus -KitRoot $kitRoot
Push-Location $PSScriptRoot
try {
    & $SjasmPlus --msg=war -I "$kitRoot" timer.asm
    if ($LASTEXITCODE -ne 0) { throw "timer.asm assembly failed" }
}
finally {
    Pop-Location
}
Write-Output "GAME.XBN written to $PSScriptRoot"
