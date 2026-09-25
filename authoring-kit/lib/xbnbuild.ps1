# xbnbuild.ps1 - build a GAME.XBN from the modules you name.
# Usage: .\xbnbuild.ps1 ticker ..\mymods\doors [-Out path\GAME.XBN] [-BaseDir dir]
# A bare name is externs\<name>\<name>.asm; an argument holding \ or / is
# a module folder, relative to -BaseDir (default: current directory).
# Hooks and scratch/state claims come from scanning each module's source.
# Resolves sjasmplus via -SjasmPlus, then tools\sjasmplus\, then PATH.
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Modules,
    [string]$Out = 'GAME.XBN',
    [string]$SjasmPlus = '',
    [string]$BaseDir = ''
)
$ErrorActionPreference = 'Stop'

$kitRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$externsDir = Join-Path $kitRoot 'externs'
if (-not $BaseDir) { $BaseDir = (Get-Location).Path }

function Fail([string]$msg) {
    [Console]::Error.WriteLine("xbnbuild: $msg")
    exit 1
}

# Bare-name modules: externs\<d>\<d>.asm, minus the prebuilt all\.
$kitModules = @(Get-ChildItem $externsDir -Directory |
    Where-Object { $_.Name -ne 'all' -and (Test-Path (Join-Path $_.FullName "$($_.Name).asm")) } |
    ForEach-Object { $_.Name })

if (-not $Modules) {
    Write-Output 'Usage: EXTERNS.BAT module [module ...]'
    Write-Output ''
    Write-Output 'Builds a GAME.XBN containing only the modules you name, writing it'
    Write-Output 'to the kit root beside BUILD.BAT. A module is a name from the list'
    Write-Output 'below, or the path of a folder holding <folder>.asm - your own'
    Write-Output 'module. You do NOT need this to use the shipped externs: every'
    Write-Output 'module ships a prebuilt GAME.XBN, and externs\all\GAME.XBN holds'
    Write-Output 'all of them.'
    Write-Output ''
    Write-Output "Modules: $($kitModules -join ' ')"
    exit 1
}

# Scan one module's MODULE blocks: entry labels at column 0 (colon
# optional, as sjasmplus allows) and SCRATCH_SIZE/STATE_SIZE equates.
# The first MODULE matching the folder name in any case fixes the name.
function Read-Module([string]$name, [string]$src) {
    $declared = $null
    $inside = $false
    $labels = @{}
    $sizes = @{}
    $n = 0
    foreach ($raw in [IO.File]::ReadAllLines($src)) {
        $n++
        $line = $raw -replace ';.*$', ''
        if ($line -match '^\s*MODULE\s+(\S+)\s*$') {
            if (-not $declared -and $Matches[1] -eq $name) { $declared = $Matches[1] }
            $inside = ($Matches[1] -ceq $declared)
            continue
        }
        if ($line -match '^\s*ENDMODULE\b') { $inside = $false; continue }
        if (-not $inside) { continue }
        if ($line -cmatch '^(ext|int|line|out)(:|\s|$)') { $labels[$Matches[1]] = $true }
        elseif ($line -cmatch '^\s+(ext|int|line|out)\s*:') {
            Fail "module '$declared': entry label '$($Matches[1])' must start at column 0 ($src line $n)"
        }
        if ($line -cmatch '^(SCRATCH_SIZE|STATE_SIZE)(\s*:?\s*=|:?\s+(?i:equ|defl)\b)') { $sizes[$Matches[1]] = $true }
    }
    if (-not $declared) { Fail "module '$name': $src has no MODULE $name block" }
    foreach ($req in 'ext', 'int') {
        if (-not $labels[$req]) { Fail "module '$declared': no '$($req):' label at column 0 in its MODULE block" }
    }
    [pscustomobject]@{
        Name    = $declared
        Line    = [bool]$labels['line']
        Out     = [bool]$labels['out']
        Scratch = [bool]$sizes['SCRATCH_SIZE']
        State   = [bool]$sizes['STATE_SIZE']
    }
}

$mods = @()
$seen = @{}
foreach ($arg in $Modules) {
    $inKit = $false
    if ($arg -match '[\\/]') {
        $dir = if ([IO.Path]::IsPathRooted($arg)) { $arg } else { Join-Path $BaseDir $arg }
        $dir = [IO.Path]::GetFullPath($dir).TrimEnd('\', '/')
        if (Test-Path $dir -PathType Container) { $dir = (Get-Item $dir).FullName.TrimEnd('\') }
        $name = Split-Path $dir -Leaf
        $kitDir = Join-Path $externsDir $name
        if ($kitModules -contains $name) {
            # A path to the kit's own module folder is that module.
            if ((Test-Path $kitDir) -and ((Get-Item $kitDir).FullName.TrimEnd('\') -eq $dir)) {
                $inKit = $true
                $name = ($kitModules | Where-Object { $_ -eq $name })
            } else {
                Fail "module '$name': the name is taken by externs\$name - rename the folder"
            }
        }
    } else {
        if ($arg -eq 'all') { Fail "'all' is the prebuilt collection, not a module - name the modules you want" }
        $match = $kitModules | Where-Object { $_ -eq $arg }
        if (-not $match) { Fail "unknown module '$arg' - known: $($kitModules -join ', ')" }
        $name = $match
        $dir = Join-Path $externsDir $name
        $inKit = $true
    }
    if ($name -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
        Fail "module '$name': a name is a letter followed by letters, digits or _"
    }
    if ($name -eq 'all') { Fail "'all' is the prebuilt collection, not a module - name the modules you want" }
    $src = Join-Path $dir "$name.asm"
    if (-not (Test-Path $src -PathType Leaf)) { Fail "module '$name': no $name.asm in $dir" }
    if ($seen.ContainsKey($name.ToLower())) { Fail "module '$name' is named twice" }
    $seen[$name.ToLower()] = $true
    $scan = Read-Module $name $src
    $name = $scan.Name
    $inc = if ($inKit) { "externs/$name/$name.asm" } else { $src -replace '\\', '/' }
    $mods += [pscustomobject]@{
        Name = $name; Include = $inc
        Line = $scan.Line; Out = $scan.Out; Scratch = $scan.Scratch; State = $scan.State
    }
}

# Assembler resolution, in order: -SjasmPlus, the kit's own tools folder,
# then PATH. EXTERNS.BAT passes -SjasmPlus from CONFIG.BAT's SJASMPLUSDIR.
. (Join-Path $PSScriptRoot 'resolve-sjasmplus.ps1')
$SjasmPlus = Resolve-SjasmPlus -SjasmPlus $SjasmPlus -KitRoot $kitRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ("xbnbuild-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $work | Out-Null

$anyLine = @($mods | Where-Object { $_.Line }).Count -gt 0
$anyOut = @($mods | Where-Object { $_.Out }).Count -gt 0

$sb = [Text.StringBuilder]::new()
[void]$sb.AppendLine('    DEVICE ZXSPECTRUMNEXT')
[void]$sb.AppendLine('    DEFINE XBN_MODULE')
foreach ($m in $mods) { [void]$sb.AppendLine("    DEFINE XBN_HAS_$($m.Name.ToUpper())") }
[void]$sb.AppendLine('    INCLUDE "xbn.inc"')
[void]$sb.AppendLine('    INCLUDE "xbnmod.inc"')
[void]$sb.AppendLine('    ORG XBN_ORG')
if ($anyLine -or $anyOut) {
    $l = if ($anyLine) { 'sub_line' } else { '0' }
    $o = if ($anyOut) { 'sub_out' } else { '0' }
    [void]$sb.AppendLine("    XBN_BEGIN3 sub_ext, sub_int, $l, $o")
} else {
    [void]$sb.AppendLine('    XBN_BEGIN sub_ext, sub_int')
}
[void]$sb.AppendLine('sub_ext:')
[void]$sb.AppendLine('    XBN_CHAIN_ENTER')
foreach ($m in $mods) {
    [void]$sb.AppendLine('    call xbn_setup')
    [void]$sb.AppendLine("    call $($m.Name).ext")
    [void]$sb.AppendLine('    XBN_CHAIN_CAPTURE')
}
[void]$sb.AppendLine('    XBN_CHAIN_VERDICT')
[void]$sb.AppendLine('sub_int:')
foreach ($m in $mods) {
    [void]$sb.AppendLine('    ld ix, XBN_FLAGS')
    [void]$sb.AppendLine("    call $($m.Name).int")
}
[void]$sb.AppendLine('    ret')
if ($anyLine) {
    [void]$sb.AppendLine('sub_line:')
    [void]$sb.AppendLine('    XBN_LINE_ENTER')
    foreach ($m in $mods) { if ($m.Line) { [void]$sb.AppendLine("    XBN_LINE_CALL $($m.Name).line") } }
    [void]$sb.AppendLine('    XBN_LINE_END')
}
if ($anyOut) {
    [void]$sb.AppendLine('sub_out:')
    foreach ($m in $mods) { if ($m.Out) { [void]$sb.AppendLine("    XBN_OUT_CALL $($m.Name).out") } }
    [void]$sb.AppendLine('    ret')
}
[void]$sb.AppendLine('    XBN_CHAIN_SETUP')
foreach ($m in $mods) {
    [void]$sb.AppendLine("    INCLUDE `"$($m.Include)`"")
}
[void]$sb.AppendLine('xbn_end:')
[void]$sb.AppendLine('    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG')
[void]$sb.AppendLine('    XBN_SCRATCH_END')

# Declared claims, placed after the collection's fixed chains in argument
# order. XBN_CLAIM_AT asserts each running total against its ceiling.
$claimers = @($mods | Where-Object { $_.Scratch -or $_.State })
if ($claimers.Count) {
    [void]$sb.AppendLine('xbn_usr_scr0 equ XBN_SCRATCH_FREE')
    [void]$sb.AppendLine('xbn_usr_st0 equ XBN_STATE_FREE')
    $i = 0
    foreach ($m in $claimers) {
        $n = $m.Name
        $scrLocal = if ($m.Scratch) { 'SCRATCH_SIZE' } else { '0' }
        $stLocal = if ($m.State) { 'STATE_SIZE' } else { '0' }
        $scrQ = if ($m.Scratch) { "$n.SCRATCH_SIZE" } else { '0' }
        $stQ = if ($m.State) { "$n.STATE_SIZE" } else { '0' }
        [void]$sb.AppendLine("    MODULE $n")
        [void]$sb.AppendLine("    XBN_CLAIM_AT xbn_usr_scr$i, $scrLocal, xbn_usr_st$i, $stLocal")
        [void]$sb.AppendLine('    ENDMODULE')
        [void]$sb.AppendLine("xbn_usr_scr$($i + 1) equ xbn_usr_scr$i + $scrQ")
        [void]$sb.AppendLine("xbn_usr_st$($i + 1) equ xbn_usr_st$i + $stQ")
        [void]$sb.AppendLine("    DISPLAY `"claim $n scratch +`", /D, xbn_usr_scr$i, `" (`", /D, $scrQ, `"), state +`", /D, xbn_usr_st$i, `" (`", /D, $stQ, `")`"")
        $i++
    }
}

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
