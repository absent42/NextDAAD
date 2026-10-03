# make-sym.ps1 - write NEXTDAAD.SYM for the CSpect DAAD debugger from the
# assembler SLD (addresses, pages) and the assembled NEX (hook check bytes).
param(
    [Parameter(Mandatory)][string]$Sld,
    [Parameter(Mandatory)][string]$Nex,
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][string]$Variant,
    [string]$Build = ''
)
$ErrorActionPreference = 'Stop'
$symNames  = 'flags','objTable','numObj','procStack','procSP','isDone','curOpcode','curCondact','curProps','indirValid','indirArg2','doallObj','doallLevel','ddbHeader','cprops'
$hookNames = 'eng_exec','err_raise'
$checkLen  = 32

# SLD record: file|line|defFile|defLine|page|value|type|data
$labels = @{}
$smc = @()
$srcCache = @{}
foreach ($line in [IO.File]::ReadAllLines($Sld)) {
    $f = $line.Split('|')
    if ($f.Count -lt 8) { continue }
    if ($f[6] -eq 'F' -and -not $labels.ContainsKey($f[7])) {
        $labels[$f[7]] = @{ Value = [int]$f[5]; Page = [int]$f[4] }
    }
    elseif ($f[6] -eq 'D' -and $f[0]) {
        $path = if ([IO.Path]::IsPathRooted($f[0])) { $f[0] } else { Join-Path $Root $f[0] }
        if (-not $srcCache.ContainsKey($path)) {
            $srcCache[$path] = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllLines($path) } else { @() }
        }
        $n = [int]$f[1]; $src = $srcCache[$path]
        # 'label equ $+n' names an instruction operand that code rewrites at run time
        if ($n -ge 1 -and $n -le $src.Count -and $src[$n - 1] -match '\bequ\s+\$\s*\+\s*\d') { $smc += [int]$f[5] }
    }
}

$nexBytes = [IO.File]::ReadAllBytes($Nex)
if ([Text.Encoding]::ASCII.GetString($nexBytes, 0, 4) -ne 'Next') { throw "make-sym: $Nex is not a NEX file" }
if ($nexBytes[10] -ne 0) { throw "make-sym: $Nex has a loading screen (header byte 10 = $($nexBytes[10])); only screenless NEX files are read" }
# NEX bank order after the 512-byte header: 5, 2, 0, 1, 3, 4, 6..111, present banks only
$bankOff = @{}; $pos = 512
foreach ($b in @(5, 2, 0, 1, 3, 4) + (6..111)) { if ($nexBytes[18 + $b]) { $bankOff[$b] = $pos; $pos += 16384 } }

function Get-NexBytes([int]$page, [int]$addr, [int]$count) {
    $bank = $page -shr 1
    if (-not $bankOff.ContainsKey($bank)) { throw ("make-sym: bank {0} (page {1}) is not in the NEX" -f $bank, $page) }
    $within = $addr -band 0x1FFF
    if ($within + $count -gt 8192) { throw ("make-sym: check range at {0:X4} crosses an 8K page" -f $addr) }
    $start = $bankOff[$bank] + ($page -band 1) * 8192 + $within
    return $nexBytes[$start..($start + $count - 1)]
}

foreach ($n in $symNames + $hookNames) {
    if (-not $labels.ContainsKey($n)) { throw "make-sym: required label '$n' not in $Sld" }
}
if ($labels['flags'].Value -ne 0xA200 -or $labels['objTable'].Value -ne 0xA300 -or $labels['numObj'].Value -ne 0xA900) {
    throw 'make-sym: frozen anchors moved (flags A200, objTable A300, numObj A900)'
}

$sb = New-Object Text.StringBuilder
[void]$sb.Append("NEXTDAAD-SYM`t1`n")
[void]$sb.Append("build`t$Build`t$Variant`n")
foreach ($n in $symNames) { [void]$sb.Append(("sym`t{0}`t{1:X4}`n" -f $n, $labels[$n].Value)) }
foreach ($n in $hookNames) {
    $v = $labels[$n].Value; $p = $labels[$n].Page
    foreach ($a in $smc) {
        if ($a -ge $v -and $a -lt $v + $checkLen) { throw ("make-sym: self-modifying operand at {0:X4} lies inside the {1} check range" -f $a, $n) }
    }
    $hex = -join (Get-NexBytes $p $v $checkLen | ForEach-Object { '{0:X2}' -f $_ })
    [void]$sb.Append(("hook`t{0}`t{1:X4}`t{2:X2}`t{3}`n" -f $n, $v, $p, $hex))
}
[IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
"wrote $Out"
