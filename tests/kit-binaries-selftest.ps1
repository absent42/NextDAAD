# The committed Linux binaries must match the pins in lib\toolversions.txt
# and the host's ndrc must print the pinned version. Throws on failure.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$lib = Join-Path $root 'authoring-kit/lib'
. (Join-Path $lib 'kitplatform.ps1')
. (Join-Path $lib 'kittools.ps1')
$pins = Read-ToolVersions $lib
$checks = 0
function Assert-Eq($a, $e, $what) { $script:checks++; if ("$a" -ne "$e") { throw "kit-binaries-selftest: $what - got '$a', expected '$e'" } }
function Sha([string]$p) { $h = [Security.Cryptography.SHA256]::Create(); try { return (-join ($h.ComputeHash([IO.File]::ReadAllBytes($p)) | ForEach-Object { $_.ToString('x2') })) } finally { $h.Dispose() } }
foreach ($k in 'NDRCVER', 'GFX2NEXT_VER', 'SJASMPLUS_VER', 'ARKOS_VER', 'PWSH_MIN', 'NDRC_LINUX_SHA256', 'GFX2NEXT_LINUX_SHA256', 'ARKOS_LINUX_URL', 'ARKOS_LINUX_SHA256', 'ARKOS_WINDOWS_URL', 'ARKOS_WINDOWS_SHA256') {
    Assert-Eq ([string]::IsNullOrEmpty($pins[$k])) $false "pin $k present"
}
$ndrcLinux = Join-Path $lib 'ndrc'
$gfxLinux = Join-Path $root 'authoring-kit/tools/gfx2next/gfx2next'
Assert-Eq (Sha $ndrcLinux) $pins['NDRC_LINUX_SHA256'] 'lib/ndrc sha256'
Assert-Eq (Sha $gfxLinux) $pins['GFX2NEXT_LINUX_SHA256'] 'tools/gfx2next/gfx2next sha256'
foreach ($f in 'authoring-kit/lib/ndrc', 'authoring-kit/tools/gfx2next/gfx2next') {
    $mode = ((& git -C $root ls-files -s -- $f) -split '\s+')[0]
    Assert-Eq $mode '100755' "$f index mode"
}
$b = [IO.File]::ReadAllBytes($ndrcLinux)
Assert-Eq (($b[0] -eq 0x7F) -and ($b[1] -eq 0x45)) $true 'lib/ndrc is ELF'
Assert-Eq ([Text.Encoding]::ASCII.GetString($b).Contains('/lib64/ld-linux')) $false 'lib/ndrc has no dynamic loader'
$hostNdrc = Join-Path $lib "ndrc$ExeSuffix"
$banner = Get-NdrcBanner $hostNdrc
Assert-Eq ("$banner ".Contains("NDRC $($pins['NDRCVER']) ")) $true "$hostNdrc banner ($banner)"
Write-Output "kit-binaries-selftest: $checks checks passed"
