# Pins that stage enumeration is case-insensitive and ordinal-sorted, so
# ext4 hash order and Linux case sensitivity cannot change output order.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. "$root/authoring-kit/lib/kitplatform.ps1"
$work = "$root/tests/out/assets-order"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force $work | Out-Null
foreach ($n in 'b.PNG', 'a.png', 'C.Png', 'notme.txt', 'NOEXT') { [IO.File]::WriteAllBytes("$work/$n", [byte[]]@(0)) }
$got = @(Get-KitFiles $work 'png' | ForEach-Object { $_.Name }) -join ','
if ($got -ne 'a.png,b.PNG,C.Png') { throw "assets-order-selftest: got $got" }
$all = @(Get-KitFiles $work '*' | ForEach-Object { $_.Name }) -join ','
if ($all -ne 'a.png,b.PNG,C.Png,NOEXT,notme.txt') { throw "assets-order-selftest: all-files form got $all" }
Write-Output 'assets-order-selftest: 2 checks passed'
