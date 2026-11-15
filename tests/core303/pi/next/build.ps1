# Assemble PI303.NEX into build\core303, with PI303.MAP: every MAP_<key> symbol as <key>=<hex>.
# Stamp = last commit touching tests/core303/pi or tests/core303/bench; dirty throws unless -AllowDirty.
param([switch]$AllowDirty, [Alias('Stamp')][string]$ForceStamp = '')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..\..").Path
$out = Join-Path $root 'build\core303'
# -Stamp (tests only) builds under build\core303\test, never the staged path.
if ($ForceStamp) { $out = Join-Path $out 'test' }
$nex = Join-Path $out 'PI303.NEX'
$map = Join-Path $out 'PI303.MAP'
# A refused or failed build leaves no NEX or MAP behind to be staged by mistake.
foreach ($f in $nex, $map) { if (Test-Path $f) { Remove-Item $f } }

$paths = @('tests/core303/pi', 'tests/core303/bench')
$hash = git -C $root log -1 --format=%h -- @paths
if ($LASTEXITCODE -ne 0) { throw "git log failed" }
$dirty = git -C $root status --porcelain -- @paths
if ($LASTEXITCODE -ne 0) { throw "git status failed" }
if (-not $hash) { $hash = 'none' }
$stamp = $hash
if ($dirty) {
    if (-not $AllowDirty) { throw "tests/core303/pi or bench has uncommitted changes: commit them first" }
    $stamp = "$hash-dirty"
}

# -Stamp forces the baked stamp: tests only.
if ($ForceStamp) { $stamp = $ForceStamp }

New-Item -ItemType Directory -Force $out | Out-Null
$src = ($PSScriptRoot -replace '\\', '/') + '/pi303.asm'
Push-Location $out
try {
    # Apostrophe string define: survives Windows argument quoting unchanged.
    & "$root\tools\sjasmplus\sjasmplus.exe" --zxnext=cspect --msg=war "-DSTAMP_STR='$stamp'" `
        --lst=PI303.lst --sym=PI303.sym --fullpath --sld=PI303.sld $src
    if ($LASTEXITCODE -ne 0) { throw "assembly failed" }
}
finally { Pop-Location }
if (-not (Test-Path $nex)) { throw "PI303.NEX not written" }

$lines = foreach ($l in Get-Content (Join-Path $out 'PI303.sym')) {
    if ($l -cmatch '^MAP_([a-z][a-z0-9_]*): EQU 0x([0-9A-F]{8})$') {
        $v = [Convert]::ToInt64($Matches[2], 16)
        if ($v -gt 0xFFFFFF) { throw "MAP_$($Matches[1]) is over 24 bits" }
        '{0}={1:X6}' -f $Matches[1], $v
    }
}
if (-not $lines) { Remove-Item $nex; throw "no MAP_ symbols in PI303.sym" }
[IO.File]::WriteAllText($map, (($lines -join "`n") + "`n"), [Text.Encoding]::ASCII)
Write-Host "stamp: $stamp"
Write-Host "built $($nex.Substring($root.Length + 1)) and PI303.MAP"
