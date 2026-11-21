# Assemble the BLT303 standalone bench into build\blt303\BLT303.NEX.
# Stamp = last commit touching tests/core303/blit, tests/core303/bench or src/ddma.inc;
# uncommitted changes there throw unless -AllowDirty.
param([switch]$AllowDirty, [Alias('Stamp')][string]$ForceStamp = '')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$out = Join-Path $root 'build\blt303'
# -Stamp (tests only) builds under build\blt303\test, never the staged path.
if ($ForceStamp) { $out = Join-Path $out 'test' }
$nex = Join-Path $out 'BLT303.NEX'
# A refused or failed build leaves no NEX behind to be staged by mistake.
if (Test-Path $nex) { Remove-Item $nex }

$hash = git -C $root log -1 --format=%h -- tests/core303/blit tests/core303/bench src/ddma.inc
if ($LASTEXITCODE -ne 0) { throw "git log failed" }
$dirty = git -C $root status --porcelain -- tests/core303/blit tests/core303/bench src/ddma.inc
if ($LASTEXITCODE -ne 0) { throw "git status failed" }
if (-not $hash) { $hash = 'none' }
$stamp = $hash
if ($dirty) {
    if (-not $AllowDirty) { throw "the BLT303 sources have uncommitted changes: commit them first" }
    $stamp = "$hash-dirty"
}

# -Stamp forces the baked stamp: tests only.
if ($ForceStamp) { $stamp = $ForceStamp }

New-Item -ItemType Directory -Force $out | Out-Null
$src = ($PSScriptRoot -replace '\\', '/') + '/blt303.asm'
Push-Location $out
try {
    # Apostrophe string define: survives Windows argument quoting unchanged.
    & "$root\tools\sjasmplus\sjasmplus.exe" --zxnext=cspect --msg=war "-DSTAMP_STR='$stamp'" `
        --lst=BLT303.lst --sym=BLT303.sym $src
    if ($LASTEXITCODE -ne 0) { if (Test-Path $nex) { Remove-Item $nex }; throw "assembly failed" }
}
finally { Pop-Location }
if (-not (Test-Path $nex)) { throw "BLT303.NEX not written" }
Write-Host "stamp: $stamp"
Write-Host "built $($nex.Substring($root.Length + 1))"
