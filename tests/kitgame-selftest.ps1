# Pins Resolve-KitGame and the three-layer Read-KitConfig.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. "$root/authoring-kit/lib/kitplatform.ps1"
. "$root/authoring-kit/lib/kitconfig.ps1"
. "$root/authoring-kit/lib/kitgame.ps1"
$checks = 0
$sep = [IO.Path]::DirectorySeparatorChar
function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ("$actual" -ne "$expected") { throw "kitgame-selftest: $what - got '$actual', expected '$expected'" }
}
function Assert-Throws([scriptblock]$Block, $expected, $what) {
    $script:checks++
    $msg = $null
    try { & $Block } catch { $msg = "$_" }
    if ($null -eq $msg) { throw "kitgame-selftest: $what - did not throw" }
    if ($msg -notlike "*$expected*") { throw "kitgame-selftest: $what - got '$msg', expected '*$expected*'" }
}
$work = "$root/tests/out/kitgame"
$n = 0
function New-Kit([string[]]$Files) {
    $script:n++
    $k = Join-Path $work "k$script:n"
    if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force }
    New-Item -ItemType Directory -Force $k | Out-Null
    foreach ($f in $Files) {
        $p = Join-Path $k $f
        New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
        [IO.File]::WriteAllText($p, '')
    }
    return (Resolve-Path -LiteralPath $k).Path
}

$k = New-Kit @('MYGAME2/MYGAME2.DSF')
$g = Resolve-KitGame @{ GAME = 'MYGAME2' } $k
Assert-Eq $g.Mode 'folder' 'folder mode'
Assert-Eq $g.Name 'MYGAME2' 'folder name'
Assert-Eq ($g.SrcRoot.EndsWith("${sep}MYGAME2")) $true 'SrcRoot ends MYGAME2'
Assert-Eq ($g.CfgFile.EndsWith("${sep}MYGAME2${sep}MYGAME2.CFG")) $true 'CfgFile'
Assert-Eq ($g.DataDir.EndsWith("RELEASE${sep}MYGAME2${sep}DATA")) $true 'DataDir'
Assert-Eq ($g.RelGame.EndsWith("RELEASE${sep}MYGAME2")) $true 'RelGame'
Assert-Eq $g.IsStarter $false 'not starter'

$k = New-Kit @('MyGame2/mygame2.dsf')
$g = Resolve-KitGame @{ GAME = 'MYGAME2' } $k
Assert-Eq $g.Mode 'folder' 'case-insensitive folder mode'
Assert-Eq $g.Name 'mygame2' 'Name as found on disk'

$k = New-Kit @('OLD.DSF')
$g = Resolve-KitGame @{ GAME = 'OLD' } $k
Assert-Eq $g.Mode 'legacy' 'legacy mode'
Assert-Eq $g.SrcRoot $k 'legacy SrcRoot is kit root'
Assert-Eq $g.CfgFile '' 'legacy has no cfg'
Assert-Eq ($g.RelGame.EndsWith("RELEASE${sep}OLD")) $true 'legacy RelGame'

$k = New-Kit @('STARTER/STARTER.DSF')
$g = Resolve-KitGame @{ GAME = '' } $k
Assert-Eq $g.Mode 'folder' 'blank GAME single folder'
Assert-Eq $g.IsStarter $true 'IsStarter'

$k = New-Kit @('STARTER/STARTER.DSF', 'MYGAME2/MYGAME2.DSF')
Assert-Throws { Resolve-KitGame @{} $k } 'ERROR: set GAME in CONFIG.local.BAT (found 0 .DSF files and 2 game folders here, need exactly one)' 'ambiguous folders'

$k = New-Kit @('LEGACY.DSF', 'STARTER/STARTER.DSF')
$g = Resolve-KitGame @{} $k
Assert-Eq $g.Mode 'legacy' 'blank GAME, root DSF plus folders is legacy'
Assert-Eq $g.Name 'LEGACY' 'legacy base name'

$k = New-Kit @('EMPTY/readme.txt')
Assert-Throws { Resolve-KitGame @{ GAME = 'EMPTY' } $k } "EMPTY${sep} has no EMPTY.DSF" 'folder without dsf'

$k = New-Kit @('x.txt')
Assert-Throws { Resolve-KitGame @{ GAME = 'NOPE' } $k } "ERROR: NOPE.DSF not found in NOPE${sep} or this folder" 'neither'

$k = New-Kit @('A.DSF', 'B.DSF')
Assert-Throws { Resolve-KitGame @{} $k } 'found 2 .DSF files and 0 game folders' 'two root dsf'

$k = New-Kit @('MYGAME2/MYGAME2.DSF', 'MYGAME2/MYGAME2.CFG')
[IO.File]::WriteAllLines("$k/CONFIG.BAT", @('SET COLS=80', 'SET KEEP=base'), [Text.Encoding]::ASCII)
[IO.File]::WriteAllLines("$k/MYGAME2/MYGAME2.CFG", @('SET COLS=40', 'SET GAME=OTHER'), [Text.Encoding]::ASCII)
[IO.File]::WriteAllLines("$k/CONFIG.local.BAT", @('SET GAME=MYGAME2', 'SET RUN=0'), [Text.Encoding]::ASCII)
$c = Read-KitConfig $k "$k/MYGAME2/MYGAME2.CFG" 6>$null
Assert-Eq $c['COLS'] '40' 'game cfg overrides base'
Assert-Eq $c['GAME'] 'MYGAME2' 'GAME in game cfg ignored'
Assert-Eq $c['RUN'] '0' 'local layer'
Assert-Eq $c['KEEP'] 'base' 'base layer kept'
$c = Read-KitConfig $k
Assert-Eq $c['COLS'] '80' 'no game cfg: base only'

Write-Output "kitgame-selftest: $checks checks passed"
