# Builds and runs the Linux parity rig, then diffs its manifests and tool
# hashes against the Windows goldens and a local tools-ab run. Exit 0/1/2.
param([switch]$Rebuild, [switch]$NoWindows, [string]$ArkosCache = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'authoring-kit/lib/kitplatform.ps1')
. (Join-Path $root 'authoring-kit/lib/kittools.ps1')
$pins = Read-ToolVersions (Join-Path $root 'authoring-kit/lib')
if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) { Write-Host 'kit-linux: docker not found'; exit 2 }
if (-not $ArkosCache) { $ArkosCache = Join-Path $root 'tests/out/tool-cache' }
function Sha([string]$p) { $h = [Security.Cryptography.SHA256]::Create(); try { return (-join ($h.ComputeHash([IO.File]::ReadAllBytes($p)) | ForEach-Object { $_.ToString('x2') })) } finally { $h.Dispose() } }

$ctx = Join-Path $root 'tests/out/docker-context'
if (Test-Path -LiteralPath $ctx) { Remove-Item -LiteralPath $ctx -Recurse -Force }
New-Item -ItemType Directory -Force "$ctx/repo", "$ctx/context" | Out-Null
foreach ($rel in (& git -C $root ls-files -- authoring-kit tests manual scripts .gitattributes)) {
    if ($rel -like 'tests/out/*') { continue }
    $dst = Join-Path "$ctx/repo" $rel
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    [IO.File]::Copy((Join-Path $root $rel), $dst, $true)
}
# Executable files by index mode: the Windows filesystem carries no modes.
$exec = & git -C $root ls-files -s -- authoring-kit tests scripts | Where-Object { $_ -match '^100755 ' } | ForEach-Object { ($_ -split "`t", 2)[1] }
# LF-only: xargs in the image keeps a CR as part of the name.
[IO.File]::WriteAllText("$ctx/exec-list.txt", ((@($exec) -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))

$arkos = "ArkosTracker-linux64-$($pins['ARKOS_VER']).zip"
$src = Join-Path $root "tools/linux/$arkos"
if (-not (Test-Path -LiteralPath $src)) {
    New-Item -ItemType Directory -Force $ArkosCache | Out-Null
    $src = Join-Path $ArkosCache $arkos
    if (-not (Test-Path -LiteralPath $src)) { Invoke-WebRequest -Uri $pins['ARKOS_LINUX_URL'] -OutFile $src }
}
if ((Sha $src) -ne $pins['ARKOS_LINUX_SHA256']) { Write-Host "kit-linux: $src does not match ARKOS_LINUX_SHA256"; exit 1 }
Copy-Item -LiteralPath $src -Destination "$ctx/context/$arkos"

$img = 'nextdaad-kit-linux'
$buildArgs = @('build', '-t', $img, '-f', (Join-Path $root 'tests/kit-parity/Dockerfile'),
    '--build-arg', "SJASMPLUS_VER=$($pins['SJASMPLUS_VER'])", '--build-arg', "ARKOS_VER=$($pins['ARKOS_VER'])")
if ($Rebuild) { $buildArgs += '--no-cache' }
& docker @buildArgs $ctx
if ($LASTEXITCODE -ne 0) { Write-Host 'kit-linux: docker build failed'; exit 1 }
$out = Join-Path $root 'tests/out/kit-linux'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Force $out | Out-Null
$env:MSYS_NO_PATHCONV = '1'
& docker run --rm -v "$([IO.Path]::GetFullPath($out)):/out" $img
$rigCode = $LASTEXITCODE
Get-Content -LiteralPath "$out/summary.txt" -Encoding UTF8 | ForEach-Object { Write-Host "  rig: $_" }

$fail = 0
foreach ($m in 'manifest.txt', 'manifest-compress.txt') {
    $g = [IO.File]::ReadAllText((Join-Path $root "tests/kit-parity/golden/$m"))
    if (-not (Test-Path -LiteralPath "$out/$m")) { $fail++; Write-Host "kit-linux: $m MISSING (rig step failed)"; continue }
    $l = [IO.File]::ReadAllText("$out/$m")
    if ($g -ceq $l) { Write-Host "kit-linux: $m identical to golden" }
    else { $fail++; Write-Host "kit-linux: $m DIFFERS"; Compare-Object ($g -split "`n") ($l -split "`n") | Out-Host }
}
if (-not $NoWindows) {
    & powershell -NoProfile -File (Join-Path $root 'tests/kit-parity/tools-ab.ps1') -Out "$out/tools-ab-windows.txt" | Out-Null
    $w = Get-Content -LiteralPath "$out/tools-ab-windows.txt" -Encoding UTF8
    $l = Get-Content -LiteralPath "$out/tools-ab.txt" -Encoding UTF8
    $d = Compare-Object $w $l
    if ($d) { $fail++; Write-Host 'kit-linux: tools-ab DIFFERS (a tool fact, not a kit bug - spec 6.7)'; $d | Out-Host }
    else { Write-Host 'kit-linux: tools-ab identical' }
}
if ($rigCode -ne 0 -or $fail) { exit 1 }
Write-Host 'kit-linux: PASS'
exit 0
