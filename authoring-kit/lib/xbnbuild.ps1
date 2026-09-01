# xbnbuild.ps1 - build a GAME.XBN containing only the modules you name.
# Usage: .\xbnbuild.ps1 ticker fade [-Out path\GAME.XBN]
# The prebuilt externs\all\GAME.XBN already contains everything; use this
# when you want a smaller binary. Resolves sjasmplus via -SjasmPlus, then
# tools\sjasmplus\, then PATH.
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Modules,
    [string]$Out = 'GAME.XBN',
    [string]$SjasmPlus = ''
)
$ErrorActionPreference = 'Stop'

$known = @{
    ticker   = 'XBN_HAS_TICKER'
    fade     = 'XBN_HAS_FADE'
    hints    = 'XBN_HAS_HINTS'
    clock    = 'XBN_HAS_CLOCK'
    timer    = 'XBN_HAS_TIMER'
    realtime = 'XBN_HAS_REALTIME'
    toolkit  = 'XBN_HAS_TOOLKIT'
    atmos    = 'XBN_HAS_ATMOS'
}

if (-not $Modules) {
    Write-Error "name at least one module: $($known.Keys -join ', ')"
    exit 1
}
foreach ($m in $Modules) {
    if (-not $known.ContainsKey($m)) {
        Write-Error "unknown module '$m' - known: $($known.Keys -join ', ')"
        exit 1
    }
    if (-not (Test-Path (Join-Path $PSScriptRoot "..\externs\$m\$m.asm"))) {
        Write-Error "module '$m' has no source at externs\$m\$m.asm"
        exit 1
    }
}

# Assembler resolution, in order: -SjasmPlus, the kit's own tools folder,
# then PATH. EXTERNS.BAT passes -SjasmPlus from CONFIG.BAT's SJASMPLUSDIR.
$kitRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $PSScriptRoot 'resolve-sjasmplus.ps1')
$SjasmPlus = Resolve-SjasmPlus -SjasmPlus $SjasmPlus -KitRoot $kitRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ("xbnbuild-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $work | Out-Null

$sb = [Text.StringBuilder]::new()
[void]$sb.AppendLine('    DEVICE ZXSPECTRUMNEXT')
[void]$sb.AppendLine('    DEFINE XBN_MODULE')
foreach ($m in $Modules) { [void]$sb.AppendLine("    DEFINE $($known[$m])") }
[void]$sb.AppendLine('    INCLUDE "xbn.inc"')
[void]$sb.AppendLine('    INCLUDE "xbnmod.inc"')
[void]$sb.AppendLine('    ORG XBN_ORG')
[void]$sb.AppendLine('    XBN_BEGIN sub_ext, sub_int')
[void]$sb.AppendLine('sub_ext:')
[void]$sb.AppendLine('    XBN_CHAIN_ENTER')
foreach ($m in $Modules) {
    [void]$sb.AppendLine('    call xbn_setup')
    [void]$sb.AppendLine("    call $m.ext")
    [void]$sb.AppendLine('    XBN_CHAIN_CAPTURE')
}
[void]$sb.AppendLine('    XBN_CHAIN_VERDICT')
[void]$sb.AppendLine('sub_int:')
foreach ($m in $Modules) {
    [void]$sb.AppendLine('    ld ix, XBN_FLAGS')
    [void]$sb.AppendLine("    call $m.int")
}
[void]$sb.AppendLine('    ret')
[void]$sb.AppendLine('    XBN_CHAIN_SETUP')
foreach ($m in $Modules) {
    [void]$sb.AppendLine("    INCLUDE `"externs/$m/$m.asm`"")
}
[void]$sb.AppendLine('xbn_end:')
[void]$sb.AppendLine('    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG')
[void]$sb.AppendLine('    XBN_SCRATCH_END')

$src = Join-Path $work 'subset.asm'
Set-Content -Path $src -Value $sb.ToString() -Encoding ASCII

# Outer try/finally cleans up $work on both the success and failure path.
try {
    Push-Location $work
    try {
        & $SjasmPlus --msg=war -I "$kitRoot" $src
        if ($LASTEXITCODE -ne 0) { throw "subset assembly failed" }
    }
    finally {
        Pop-Location
    }
    Copy-Item (Join-Path $work 'GAME.XBN') $Out -Force
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
$len = (Get-Item $Out).Length
Write-Output "$Out written: $len bytes, $(16384 - $len) free of 16384"
