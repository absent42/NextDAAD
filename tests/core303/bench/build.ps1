# Assemble the CORE303 standalone bench into build\core303\CORE303.NEX.
# Stamp = last commit touching tests/core303/bench; a dirty folder throws unless -AllowDirty.
param([switch]$AllowDirty)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$out = Join-Path $root 'build\core303'
$nex = Join-Path $out 'CORE303.NEX'
# A refused or failed build leaves no NEX behind to be staged by mistake.
if (Test-Path $nex) { Remove-Item $nex }

$hash = git -C $root log -1 --format=%h -- tests/core303/bench
if ($LASTEXITCODE -ne 0) { throw "git log failed" }
$dirty = git -C $root status --porcelain -- tests/core303/bench
if ($LASTEXITCODE -ne 0) { throw "git status failed" }
if (-not $hash) { $hash = 'none' }
$stamp = $hash
if ($dirty) {
    if (-not $AllowDirty) { throw "tests/core303/bench has uncommitted changes: commit them first" }
    $stamp = "$hash-dirty"
}

New-Item -ItemType Directory -Force $out | Out-Null
$src = ($PSScriptRoot -replace '\\', '/') + '/core303.asm'
Push-Location $out
try {
    # Apostrophe string define: survives Windows argument quoting unchanged.
    & "$root\tools\sjasmplus\sjasmplus.exe" --zxnext=cspect --msg=war "-DSTAMP_STR='$stamp'" `
        --lst=CORE303.lst $src
    if ($LASTEXITCODE -ne 0) { throw "assembly failed" }
}
finally { Pop-Location }
if (-not (Test-Path $nex)) { throw "CORE303.NEX not written" }
Write-Host "stamp: $stamp"
Write-Host "built build\core303\CORE303.NEX"
