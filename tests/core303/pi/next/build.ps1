# Assemble PI303.NEX and PI303V.NEX into build\core303, each with its <NAME>.MAP: every
# MAP_<key> symbol as <key>=<hex>. -Target builds one. Stamp = last commit touching
# tests/core303/pi or tests/core303/bench; dirty throws unless -AllowDirty.
param([switch]$AllowDirty, [Alias('Stamp')][string]$ForceStamp = '',
    [ValidateSet('All', 'PI303', 'PI303V')][string]$Target = 'All')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..\..").Path
$out = Join-Path $root 'build\core303'
# -Stamp (tests only) builds under build\core303\test, never the staged path.
if ($ForceStamp) { $out = Join-Path $out 'test' }
$names = if ($Target -eq 'All') { @('PI303', 'PI303V') } else { @($Target) }
$outputs = foreach ($n in $names) { (Join-Path $out "$n.NEX"), (Join-Path $out "$n.MAP") }
# A refused or failed build leaves no NEX or MAP behind to be staged by mistake.
function Remove-Outputs { foreach ($f in $outputs) { if (Test-Path $f) { Remove-Item $f } } }
Remove-Outputs

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

function Build-Nex([string]$name) {
    $nex = Join-Path $out "$name.NEX"
    $map = Join-Path $out "$name.MAP"
    $src = ($PSScriptRoot -replace '\\', '/') + '/' + $name.ToLower() + '.asm'
    Push-Location $out
    try {
        # Apostrophe string define: survives Windows argument quoting unchanged.
        & "$root\tools\sjasmplus\sjasmplus.exe" --zxnext=cspect --msg=war "-DSTAMP_STR='$stamp'" `
            --lst="$name.lst" --sym="$name.sym" --fullpath --sld="$name.sld" $src
        if ($LASTEXITCODE -ne 0) { throw "$name assembly failed" }
    }
    finally { Pop-Location }
    if (-not (Test-Path $nex)) { throw "$name.NEX not written" }

    $lines = foreach ($l in Get-Content (Join-Path $out "$name.sym")) {
        if ($l -cmatch '^MAP_([a-z][a-z0-9_]*): EQU 0x([0-9A-F]{8})$') {
            $v = [Convert]::ToInt64($Matches[2], 16)
            if ($v -gt 0xFFFFFF) { throw "$name MAP_$($Matches[1]) is over 24 bits" }
            '{0}={1:X6}' -f $Matches[1], $v
        }
    }
    if (-not $lines) { throw "no MAP_ symbols in $name.sym" }
    [IO.File]::WriteAllText($map, (($lines -join "`n") + "`n"), [Text.Encoding]::ASCII)
}

try { foreach ($n in $names) { Build-Nex $n } }
catch { Remove-Outputs; throw }
Write-Host "stamp: $stamp"
foreach ($n in $names) { Write-Host "built $((Join-Path $out "$n.NEX").Substring($root.Length + 1)) and $n.MAP" }
