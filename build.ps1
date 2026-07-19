param([switch]$Run, [switch]$Clean, [switch]$Release, [switch]$Force1MB, [switch]$Kit)
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
    # -Kit implies a release build (the kit ships the non-debug interpreter).
    if (-not ($Release -or $Kit)) { $defs += '-DDEBUG=1' }
    if ($Force1MB)                { $defs += '-DFORCE_1MB=1' }
    # DAC signedness is UNSIGNED everywhere on the CPU-OUT path - one convention,
    # no build toggle (the -DacCSpect accommodation was retired once the OUT path
    # was confirmed unsigned on CSpect too; see nextdaad.inc DAC_SILENCE).
    & "$root\tools\sjasmplus\sjasmplus.exe" --zxnext=cspect --msg=war --fullpath --sld="$root\build\nextdaad.sld" @defs "src/main.asm"
    if ($LASTEXITCODE -ne 0) { throw "assembly failed" }
    Write-Host "built build\nextdaad.nex"
    # Only -Kit publishes the interpreter into the shippable authoring kit, so
    # routine -Release dev builds never overwrite the kit's committed nextdaad.nex.
    if ($Kit) {
        Copy-Item "$root\build\nextdaad.nex" "$root\authoring-kit\nextdaad.nex" -Force
        Write-Host "placed authoring-kit\nextdaad.nex (kit interpreter refreshed)"
    }
    if ($Run) {
        & "$root\tools\CSpect\CSpect.exe" -w3 -zxnext -esc -mmc="$root\sd\" "$root\build\nextdaad.nex"
    }
}
finally { Pop-Location }
