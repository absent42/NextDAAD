# -Run mounts ONE staged leg folder as the emulated card. tests\
# build-tests.ps1 stages into sd\<LEG>\ subfolders (see its LEG FOLDERS
# header block) rather than the sd\ root, and a NextDAAD game reads
# GAME.DDB and every asset from the directory it was launched from - so
# the folder, not sd\, is what has to be the card root.
#   -Leg <name>   mount sd\<name>\ (SUITE, VID, SFXDI, RAB, ...)
#   (omitted)     mount the most recently staged sd\*\GAME.DDB's folder,
#                 falling back to sd\ itself if nothing is staged
param([switch]$Run, [switch]$Clean, [switch]$Release, [switch]$Force1MB, [switch]$Kit, [string]$Leg)
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
    # DMA-accelerated picture copies (SP11 Task 2) are unconditional - the
    # owner's -NoDmaGfx A/B lever closed 2026-07-21 (kit Release build,
    # real hardware: location-art DMA blit during sample playback, clean
    # draw) and retired with its CPU-only fallback (src/overlay2.asm).
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
        & python "$root\scripts\build_manual.py"
        if ($LASTEXITCODE -ne 0) { throw "manual generation failed - the kit would ship stale or missing docs" }
    }
    if ($Run) {
        if ($Leg) {
            $mmc = "$root\sd\$Leg"
            if (-not (Test-Path -LiteralPath "$mmc\GAME.DDB")) {
                throw "no $mmc\GAME.DDB - stage that leg first (tests\build-tests.ps1 -$Leg or the switch that owns it)"
            }
        }
        else {
            $staged = Get-ChildItem "$root\sd\*\GAME.DDB" -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $mmc = if ($staged) { $staged.DirectoryName } else { "$root\sd" }
        }
        Write-Host "mounting $mmc\ as the card"
        & "$root\tools\CSpect\CSpect.exe" -w3 -zxnext -esc -mmc="$mmc\" "$root\build\nextdaad.nex"
    }
}
finally { Pop-Location }
