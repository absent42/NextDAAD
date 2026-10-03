# Pins make-sym.ps1: SLD label lookup, NEX bank mapping for check bytes,
# and the self-modifying-operand and missing-label refusals.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$work = "$root/tests/out/make-sym"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force "$work/src" | Out-Null

$names = 'flags','objTable','numObj','procStack','procSP','isDone','curOpcode','curCondact','curProps','indirValid','indirArg2','doallObj','doallLevel','ddbHeader','cprops'
function New-Sld([int]$smcAddr, [string]$drop) {
    $l = @('|SLD.data.version|1')
    $addr = 0xA200
    foreach ($n in $names) {
        if ($n -eq $drop) { continue }
        $v = switch ($n) { 'flags' { 0xA200 } 'objTable' { 0xA300 } 'numObj' { 0xA900 } default { $addr } }
        $l += "src/a.asm|1||0|5|$v|F|$n"
        $addr += 2
    }
    $l += 'src/a.asm|1||0|4|36864|F|eng_exec'          # $9000, page 4
    $l += 'src/a.asm|1||0|4|36928|F|err_raise'         # $9040, page 4
    $l += "src/a.asm|3||0|-1|$smcAddr|D|smcOperand"
    [IO.File]::WriteAllLines("$work/test.sld", $l)
}
[IO.File]::WriteAllLines("$work/src/a.asm", @('; a', '; b', 'smcOperand equ $+1'))

# NEX: 512-byte header, banks 5 and 2 present, so bank 2 starts at 512+16384.
$nex = New-Object byte[] (512 + 2 * 16384)
[Text.Encoding]::ASCII.GetBytes('NextV1.2').CopyTo($nex, 0)
$nex[18 + 5] = 1; $nex[18 + 2] = 1
$bank2 = 512 + 16384
for ($i = 0; $i -lt 32; $i++) { $nex[$bank2 + 0x1000 + $i] = [byte](0xA0 + $i) }   # $9000 = page 4 offset $1000
[IO.File]::WriteAllBytes("$work/test.nex", $nex)

$ms = "$root/scripts/make-sym.ps1"
$checks = 0

New-Sld 0x8000 ''
& $ms -Sld "$work/test.sld" -Nex "$work/test.nex" -Root $work -Out "$work/OK.SYM" -Variant DEBUG -Build abc1234 | Out-Null
$t = [IO.File]::ReadAllText("$work/OK.SYM")
if (-not $t.StartsWith("NEXTDAAD-SYM`t1`n")) { throw "make-sym-selftest: bad header" }
if ($t -notmatch "build`tabc1234`tDEBUG`n") { throw "make-sym-selftest: bad build line" }
if ($t -notmatch "sym`tflags`tA200`n") { throw "make-sym-selftest: flags sym missing" }
$want = -join (0..31 | ForEach-Object { '{0:X2}' -f (0xA0 + $_) })
if ($t -notmatch "hook`teng_exec`t9000`t04`t$want`n") { throw "make-sym-selftest: eng_exec hook bytes wrong" }
$checks++

New-Sld 0x9010 ''                                       # SMC operand inside eng_exec's range
$threw = $false
try { & $ms -Sld "$work/test.sld" -Nex "$work/test.nex" -Root $work -Out "$work/BAD.SYM" -Variant DEBUG | Out-Null } catch { $threw = $_.Exception.Message -match 'self-modifying' }
if (-not $threw) { throw "make-sym-selftest: SMC inside check range not refused" }
$checks++

New-Sld 0x8000 'procSP'
$threw = $false
try { & $ms -Sld "$work/test.sld" -Nex "$work/test.nex" -Root $work -Out "$work/BAD.SYM" -Variant DEBUG | Out-Null } catch { $threw = $_.Exception.Message -match "procSP" }
if (-not $threw) { throw "make-sym-selftest: missing label not refused" }
$checks++

Write-Output "make-sym-selftest: $checks checks passed"
