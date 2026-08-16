# Assembles fade.asm into GAME.XBN in this directory.
# Requires sjasmplus on PATH, or set SJASMPLUS to the executable.
$ErrorActionPreference = 'Stop'
$sj = if ($env:SJASMPLUS) { $env:SJASMPLUS } else { 'sjasmplus' }
if (-not (Get-Command $sj -ErrorAction SilentlyContinue)) {
    throw "sjasmplus not found - put it on PATH or set SJASMPLUS to the executable"
}
$kit = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Push-Location $PSScriptRoot
try {
    & $sj --msg=war -I "$kit" "$PSScriptRoot\fade.asm"
    if ($LASTEXITCODE -ne 0) { throw 'assembly failed' }
    Write-Host "built GAME.XBN ($((Get-Item GAME.XBN).Length) bytes)"
}
finally { Pop-Location }
