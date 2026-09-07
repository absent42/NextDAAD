$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
if (-not (Test-Path "$root\tools\NextDAW\RuntimePlayer\NextDAW_RuntimePlayer_E000.bin")) { throw "tools\NextDAW is absent - this spike needs the author's own NextDAW copy" }
Push-Location $PSScriptRoot
try {
    & "$root\tools\sjasmplus\sjasmplus.exe" --zxnext=cspect --msg=war spike.asm
    if ($LASTEXITCODE -ne 0) { throw "assembly failed" }
    Write-Host "built tests\spikes\ndaw\spike.nex"
}
finally { Pop-Location }
