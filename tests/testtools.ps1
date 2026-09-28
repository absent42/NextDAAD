# testtools.ps1 - dot-source. Selftest host resolution for 5.1, pwsh and the Linux rig.
# $root is forward-slash only: gfx2next.exe mis-derives output names from
# mixed-separator paths on Windows.
$root = (Split-Path $PSScriptRoot) -replace '\\', '/'
. (Join-Path $root 'authoring-kit/lib/kitplatform.ps1')
$TestExe = $ExeSuffix
$TestPsHost = if ($OnWindows) { 'powershell' } else { 'pwsh' }

# Windows: the repo tools\ tree. Linux: $env:NEXTDAAD_TOOLS for sjasmplus and
# Arkos, PATH for ffmpeg, the committed authoring-kit/tools/gfx2next for gfx2next.
function Get-RepoTool([string]$Name) {
    if ($OnWindows) {
        $map = @{
            gfx2next           = 'tools/gfx2next/gfx2next.exe'
            sjasmplus          = 'tools/sjasmplus/sjasmplus.exe'
            SongToAky          = 'tools/ArkosTracker3/tools/SongToAky.exe'
            SongToYm           = 'tools/ArkosTracker3/tools/SongToYm.exe'
            SongToSoundEffects = 'tools/ArkosTracker3/tools/SongToSoundEffects.exe'
            ffmpeg             = 'tools/ffmpeg/bin/ffmpeg.exe'
        }
        return Join-Path $root $map[$Name]
    }
    if ($Name -eq 'gfx2next') { return Join-Path $root 'authoring-kit/tools/gfx2next/gfx2next' }
    if ($Name -eq 'ffmpeg') {
        $c = Get-Command ffmpeg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return $c.Source }
        return 'ffmpeg'
    }
    $sub = @{
        sjasmplus          = 'sjasmplus/sjasmplus'
        SongToAky          = 'ArkosTracker3/tools/SongToAky'
        SongToYm           = 'ArkosTracker3/tools/SongToYm'
        SongToSoundEffects = 'ArkosTracker3/tools/SongToSoundEffects'
    }
    if ($env:NEXTDAAD_TOOLS) { return Join-Path $env:NEXTDAAD_TOOLS $sub[$Name] }
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $Name
}

# Prints "<selftest>: <why>". $MyInvocation.PSCommandPath here is the
# calling script's path, not testtools.ps1's.
function Skip-Leg([string]$Why) {
    $name = [IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath)
    Write-Host "${name}: $Why"
}
