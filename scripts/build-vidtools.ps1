# Build authoring-kit\tools\vidtools\ (videnc.exe + vidtune.exe, one
# PyInstaller onedir bundle) from scripts\vidtools.spec, verify it and deploy.
#   -OutDir <dir>  build tree, must be outside the repo (default %TEMP%\nextdaad-vidtools)
#   -NoDeploy      build and verify only; leave the kit untouched
# Needs `python` with PyInstaller, PySide6, numpy and Pillow (not `py -3`).
param([string]$OutDir = (Join-Path $env:TEMP 'nextdaad-vidtools'), [switch]$NoDeploy)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$OutDir = [IO.Path]::GetFullPath($OutDir)
if (($OutDir + '\').StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "-OutDir must be outside the repo: $OutDir"
}

& python -c "import PyInstaller, PySide6, numpy, PIL" 2>$null
if ($LASTEXITCODE -ne 0) { throw "python lacks PyInstaller/PySide6/numpy/Pillow" }

& python -m PyInstaller --noconfirm --log-level WARN `
    --distpath "$OutDir\dist" --workpath "$OutDir\work" "$PSScriptRoot\vidtools.spec"
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed" }
$dist = Join-Path $OutDir 'dist\vidtools'

# Licences: the committed texts plus the ones shipped by the build environment.
$lic = Join-Path $dist 'LICENSES'
New-Item -ItemType Directory -Force $lic | Out-Null
Copy-Item "$PSScriptRoot\vidtools-licenses\*" $lic
$pick = @'
import sys
from importlib.metadata import distribution
from pathlib import Path
print(Path(sys.base_prefix, "LICENSE.txt"), "Python-LICENSE.txt", sep="|")
for dist, name, out in (("numpy", "LICENSE.txt", "numpy-LICENSE.txt"),
                        ("pillow", "LICENSE", "Pillow-LICENSE.txt"),
                        ("pyinstaller", "COPYING.txt", "PyInstaller-COPYING.txt")):
    d = distribution(dist)
    f = next(f for f in d.files if f.name == name and "dist-info" in str(f))
    print(d.locate_file(f), out, sep="|")
'@
foreach ($line in (& python -c $pick)) {
    $src, $name = $line -split '\|'
    Copy-Item $src (Join-Path $lic $name)
}

& python "$root\tests\check_frozen_exes.py" $dist
if ($LASTEXITCODE -ne 0) { throw "built bundle failed check_frozen_exes" }
if ($NoDeploy) { Write-Host "built $dist (not deployed)"; return }

$target = Join-Path $root 'authoring-kit\tools\vidtools'
if (Get-ChildItem $target -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue) {
    throw "refusing to mirror into $target - it contains a junction or symlink"
}
robocopy $dist $target /MIR /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
& python "$root\tests\check_frozen_exes.py"
if ($LASTEXITCODE -ne 0) { throw "deployed bundle failed check_frozen_exes" }
Write-Host "deployed $target"
