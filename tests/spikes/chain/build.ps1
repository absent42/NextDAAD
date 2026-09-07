$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
Push-Location $PSScriptRoot
try {
    & "$root\tools\sjasmplus\sjasmplus.exe" --zxnext=cspect --msg=war spike.asm
    if ($LASTEXITCODE -ne 0) { throw "assembly failed" }
    Write-Host "built tests\spikes\chain\spike.nex"
}
finally { Pop-Location }
