# Host build of the Pi C tools with mingw gcc into build\core303\host (warnings are errors).
param([string]$Gcc = "C:\ProgramData\mingw64\mingw64\bin\gcc.exe")
$ErrorActionPreference = "Stop"
$src = $PSScriptRoot
$root = (Resolve-Path (Join-Path $src "..\..\..\..")).Path
$out = Join-Path $root "build\core303\host"
if (-not (Test-Path $Gcc)) { Write-Error "gcc not found: $Gcc" }
New-Item -ItemType Directory -Force $out | Out-Null
$env:PATH = (Split-Path $Gcc) + ";" + $env:PATH
$flags = @("-O2", "-std=c99", "-Wall", "-Wextra", "-Werror", "-static")
$core = Join-Path $src "core303pi.c"
$jobs = @(
    @{ exe = "test_core303pi.exe"; srcs = @($core, (Join-Path $src "test_core303pi.c")) },
    @{ exe = "spi303.exe"; srcs = @($core, (Join-Path $src "spi303.c")) },
    @{ exe = "prep303.exe"; srcs = @($core, (Join-Path $src "prep303.c")) }
)
foreach ($j in $jobs) {
    & $Gcc @flags "-I$src" -o (Join-Path $out $j.exe) @($j.srcs) 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { Write-Error "gcc failed: $($j.exe)" }
}
Write-Host "built $out"
