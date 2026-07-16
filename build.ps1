param([switch]$Run, [switch]$Clean, [switch]$Release, [switch]$Force1MB)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Push-Location $root
try {
    if ($Clean) {
        if (Test-Path "$root\build") { Remove-Item -Recurse -Force "$root\build" }
        Write-Host "clean done"
        return
    }
    New-Item -ItemType Directory -Force "$root\build" | Out-Null
    $defs = @()
    if (-not $Release) { $defs += '-DDEBUG=1' }
    if ($Force1MB)     { $defs += '-DFORCE_1MB=1' }
    & "$root\tools\sjasmplus\sjasmplus.exe" --zxnext=cspect --msg=war --fullpath --sld="$root\build\nextdaad.sld" @defs "src\main.asm"
    if ($LASTEXITCODE -ne 0) { throw "assembly failed" }
    Write-Host "built build\nextdaad.nex"
    if ($Run) {
        & "$root\tools\CSpect\CSpect.exe" -w3 -zxnext -esc -mmc="$root\sd\" "$root\build\nextdaad.nex"
    }
}
finally { Pop-Location }
