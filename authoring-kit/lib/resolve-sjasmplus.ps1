# resolve-sjasmplus.ps1 - shared assembler resolution ladder for the
# extern build.ps1 scripts and xbnbuild.ps1. Dot-source this, then call
# Resolve-SjasmPlus.
#
# Order: -SjasmPlus param, then the kit's tools\sjasmplus\ (root or one
# nested subfolder, as a zip extract can leave it), then PATH.

. (Join-Path $PSScriptRoot 'kitplatform.ps1')

function Resolve-SjasmPlus {
    param(
        [string]$SjasmPlus = '',
        [Parameter(Mandatory = $true)][string]$KitRoot
    )
    if (-not $SjasmPlus) {
        $dir = Join-Path $KitRoot (Join-Path 'tools' 'sjasmplus')
        $bundled = Join-Path $dir "sjasmplus$ExeSuffix"
        if (Test-Path $bundled) { $SjasmPlus = $bundled }
        else {
            $nested = Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
                      ForEach-Object { Join-Path $_.FullName "sjasmplus$ExeSuffix" } |
                      Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($nested) { $SjasmPlus = $nested }
        }
    }
    if (-not $SjasmPlus) {
        $onPath = Get-Command "sjasmplus$ExeSuffix" -ErrorAction SilentlyContinue
        if ($onPath) { $SjasmPlus = $onPath.Source }
    }
    if (-not $SjasmPlus -or -not (Test-Path $SjasmPlus)) {
        Write-Error "sjasmplus.exe not found. Download it from https://github.com/z00m128/sjasmplus and extract it into tools\sjasmplus\, or set SJASMPLUSDIR in CONFIG.BAT, or put it on PATH."
        exit 1
    }
    # Absolute path: relative here breaks once the caller changes directory.
    return (Resolve-Path $SjasmPlus).Path
}
