# testtools.ps1 - dot-source. Shared host resolution for tests/*-selftest.ps1
# so a selftest runs unmodified under Windows PowerShell 5.1, pwsh on
# Windows, and pwsh in the Linux parity rig.
# Forward-slash only: a selftest that appends "/literal/segments" to $root
# must never end up with a MIXED-separator string, which gfx2next.exe's own
# output-filename logic (not a normal path API) gets wrong on Windows.
$root = (Split-Path $PSScriptRoot) -replace '\\', '/'
. (Join-Path $root 'authoring-kit/lib/kitplatform.ps1')
$TestExe = $ExeSuffix
$TestPsHost = if ($OnWindows) { 'powershell' } else { 'pwsh' }

# The repo's own tools\ tree on Windows. On Linux: $env:NEXTDAAD_TOOLS's
# layout (the parity rig sets it) for sjasmplus and the Arkos tools, PATH
# for ffmpeg, and the kit's own committed authoring-kit/tools/gfx2next
# copy for gfx2next - none of those three live under $env:NEXTDAAD_TOOLS.
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

# Prints "<selftest>: <why>" and returns; the caller wraps the unportable
# leg in if ($OnWindows) { <leg> } else { Skip-Leg '<leg> skipped - ...' }.
# $MyInvocation.PSCommandPath inside a dot-sourced function is the CALLING
# script's path, not testtools.ps1's own.
function Skip-Leg([string]$Why) {
    $name = [IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath)
    Write-Host "${name}: $Why"
}
