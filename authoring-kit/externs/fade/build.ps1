# build.ps1 - assembles fade.asm into GAME.XBN in this directory.
# Assembler resolution: -SjasmPlus, then the kit's tools\sjasmplus\, then PATH.
param([string]$SjasmPlus = '')
$ErrorActionPreference = 'Stop'
$kitRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
if (-not $SjasmPlus) {
    $dir = Join-Path $kitRoot 'tools\sjasmplus'
    $bundled = Join-Path $dir 'sjasmplus.exe'
    if (Test-Path $bundled) { $SjasmPlus = $bundled }
    else {
        $nested = Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
                  ForEach-Object { Join-Path $_.FullName 'sjasmplus.exe' } |
                  Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($nested) { $SjasmPlus = $nested }
    }
}
if (-not $SjasmPlus) {
    $onPath = Get-Command sjasmplus.exe -ErrorAction SilentlyContinue
    if ($onPath) { $SjasmPlus = $onPath.Source }
}
if (-not $SjasmPlus -or -not (Test-Path $SjasmPlus)) {
    Write-Error "sjasmplus.exe not found. Download it from https://github.com/z00m128/sjasmplus and extract it into tools\sjasmplus\, or set SJASMPLUSDIR in CONFIG.BAT, or put it on PATH."
    exit 1
}
# Absolute path: relative here breaks once Push-Location changes the
# working directory below.
$SjasmPlus = (Resolve-Path $SjasmPlus).Path
Push-Location $PSScriptRoot
try {
    & $SjasmPlus --msg=war -I "$kitRoot" fade.asm
    if ($LASTEXITCODE -ne 0) { throw "fade.asm assembly failed" }
}
finally {
    Pop-Location
}
Write-Output "GAME.XBN written to $PSScriptRoot"
