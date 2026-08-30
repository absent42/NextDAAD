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
if (-not $SjasmPlus) {
    # Two shapes, as tools.bat already accepts for Arkos and ffmpeg: the exe
    # at the folder root, or one level down if the zip nested a folder.
    $dir = Join-Path $kitRoot 'tools\sjasmplus'
    $bundled = Join-Path $dir 'sjasmplus.exe'
    if (Test-Path $bundled) { $SjasmPlus = $bundled }
    else {
        $nested = Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
                  ForEach-Object { Join-Path $_.FullName 'sjasmplus.exe' } |
                  Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($nested) { $SjasmPlus = $nested }
    }
}
if (-not $SjasmPlus) {
    $onPath = Get-Command sjasmplus.exe -ErrorAction SilentlyContinue
    if ($onPath) { $SjasmPlus = $onPath.Source }
}
if (-not $SjasmPlus -or -not (Test-Path $SjasmPlus)) {
    Write-Error "sjasmplus.exe not found. Download it from https://github.com/z00m128/sjasmplus and extract it into tools\sjasmplus\, or set SJASMPLUSDIR in CONFIG.BAT, or put it on PATH."
    exit 1
}
# Absolute path: relative here breaks once Push-Location changes the
# working directory below.
$SjasmPlus = (Resolve-Path $SjasmPlus).Path
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
}
[void]$sb.AppendLine('    ret')
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
