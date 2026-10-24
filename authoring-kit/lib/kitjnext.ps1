# kitjnext.ps1 - dot-source after kitplatform.ps1. jNext card helpers: AUTOEXEC.BAS writer and 8.3 names.
if ($null -eq (Get-Variable OnWindows -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'kitplatform.ps1') }

# +3DOS BASIC file: 128-byte header then plain-text lines, no tokeniser.
# NextZXOS +3DOS file header, as in the distribution's own .bas files.
function New-AutoexecBas([string]$CardDir, [string]$Nex) {
    $prog = New-Object System.Collections.Generic.List[byte]
    $n = 10
    foreach ($text in ".cd /$CardDir", ".nexload $Nex") {
        $t = [Text.Encoding]::ASCII.GetBytes($text)
        $len = $t.Length + 1
        $prog.Add([byte]($n -shr 8)); $prog.Add([byte]($n -band 255))
        $prog.Add([byte]($len -band 255)); $prog.Add([byte]($len -shr 8))
        $prog.AddRange($t); $prog.Add([byte]13)
        $n += 10
    }
    $plen = $prog.Count
    $total = 128 + $plen
    $h = New-Object byte[] 128
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('PLUS3DOS'), $h, 8)
    $h[8] = 0x1A; $h[9] = 1; $h[10] = 0
    for ($i = 0; $i -lt 4; $i++) { $h[11 + $i] = [byte](($total -shr (8 * $i)) -band 255) }
    $h[15] = 0
    $h[16] = [byte]($plen -band 255); $h[17] = [byte]($plen -shr 8)
    $h[18] = 10; $h[19] = 0
    $h[20] = $h[16]; $h[21] = $h[17]
    $sum = 0
    for ($i = 0; $i -lt 127; $i++) { $sum += $h[$i] }
    $h[127] = [byte]($sum % 256)
    return [byte[]]($h + $prog.ToArray())
}

# 8.3-safe card folder name: upper-case, other chars become X, max 8, never empty.
function Get-JNextCardName([string]$Game) {
    $s = ([regex]::Replace($Game.ToUpperInvariant(), '[^A-Z0-9_-]', 'X'))
    if ($s.Length -gt 8) { $s = $s.Substring(0, 8) }
    if ($s.Length -eq 0) { return 'GAME' }
    return $s
}

# NEX file name .nexload can take from an 8.3 card folder; anything else is staged as RUN.NEX.
function Get-JNextLaunchNex([string]$NexFile) {
    if ($NexFile -match '^[A-Za-z0-9_-]{1,8}\.[Nn][Ee][Xx]$') { return $NexFile.ToUpperInvariant() }
    return 'RUN.NEX'
}

# jnext.exe is a GUI-subsystem exe: the pipe makes the shell wait for it to finish.
function Invoke-JNextTool([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-Host
    return $LASTEXITCODE
}

# Copies the base image to $Card and adds AUTOEXEC.BAS and the game; returns the card folder name.
function Publish-JNextCard([string]$Exe, [string]$BaseImage, [string]$Card, [string]$GameDir, [string]$NexFile, [string]$WorkDir) {
    $cardDir = Get-JNextCardName ([IO.Path]::GetFileNameWithoutExtension($NexFile))
    $launch = Get-JNextLaunchNex $NexFile
    New-Item -ItemType Directory -Path (Split-Path -Parent $Card) -Force | Out-Null
    Copy-Item -LiteralPath $BaseImage -Destination $Card -Force
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $bas = Join-Path $WorkDir 'AUTOEXEC.BAS'
    [IO.File]::WriteAllBytes($bas, [byte[]](New-AutoexecBas $cardDir $launch))
    $calls = @(, @('--sdcard', $Card, '--sdcard-file-add', $bas, '--sdcard-file-dest', '/NEXTZXOS/AUTOEXEC.BAS', '--sdcard-file-force'))
    $calls += , @('--sdcard', $Card, '--sdcard-file-add', $GameDir, '--sdcard-file-dest', "/$cardDir")
    if ($launch -eq 'RUN.NEX') {
        $calls += , @('--sdcard', $Card, '--sdcard-file-add', (Join-Path $GameDir $NexFile), '--sdcard-file-dest', "/$cardDir/RUN.NEX")
    }
    $step = 0
    foreach ($c in $calls) {
        $step++
        $rc = Invoke-JNextTool $Exe $c
        if ($rc -ne 0) { throw "ERROR: jNext could not write the SD-card image (step $step, exit $rc)" }
    }
    return $cardDir
}

# Windows: the process is jnext. Linux: pgrep -x jnext.
function Test-JNextRunning {
    if ($OnWindows) { return (@(Get-Process -Name jnext -ErrorAction SilentlyContinue).Count -gt 0) }
    $pg = Get-Command pgrep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pg) { Write-Host 'note: pgrep not found - the running-jNext check is skipped'; return $false }
    & $pg.Source -x jnext *> $null
    return ($LASTEXITCODE -eq 0)
}
