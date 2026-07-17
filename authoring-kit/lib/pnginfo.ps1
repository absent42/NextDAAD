param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
$name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
$m = [regex]::Match($name, '\d+')
if (-not $m.Success) { Write-Output 'ERR:noname'; return }
$num = '{0:D3}' -f [int]$m.Value
$b = [System.IO.File]::ReadAllBytes($Path)
if ($b.Length -lt 24) { Write-Output 'ERR:short'; return }
# PNG: 8-byte signature, then IHDR length(4) + type(4); width is bytes 16-19 big-endian.
$w = ([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19]
if     ($w -eq 320) { Write-Output "$num NX2" }
elseif ($w -eq 256) { Write-Output "$num NXI" }
else                { Write-Output "ERR:$w" }
