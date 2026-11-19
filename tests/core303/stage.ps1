# Build and stage the CORE303 silicon legs: sd\LEG303A\ (standalone bench), sd\LEG303B\
# (BENCH interpreter + fixture), sd\LEG303C\ (NXB video bench), indexed by sd\LEG303.TXT.

# Legs are assembled under tests\out\core303-stage\ and copied into sd\ only after every
# gate and stamp passed (build-tests.ps1 -NxBench regenerates sd\NXBENCH\ itself).

# -WhatIf lists the plan and builds nothing. -SdRoot replaces sd\ as the leg root (tests).

# Phase 2: -Ks3Rerun (sd\LEG303A3-C3 from the KS1 staged record), -Phase2 (sd\LEG303P0-P4 plus
# a <date>-<board>-staged record), -P2Only (sd\LEG303P2<BOARD>); -PushPi copies the Pi bundle.
# -ResultsRoot and -StagedRecord (tests) replace the results root and the KS1 record.
param([switch]$WhatIf, [string]$SdRoot,
    [switch]$Ks3Rerun, [switch]$Phase2, [switch]$P2Only, [switch]$PushPi,
    [string]$Board, [string]$Date, [string]$PiHost = 'root@10.1.10.107',
    [string]$ResultsRoot, [string]$StagedRecord)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
$sdReal = Join-Path $root 'sd'
$sd = if ($SdRoot) { (Resolve-Path -LiteralPath $SdRoot).Path } else { $sdReal }
$work = Join-Path $root 'tests\out\core303-stage'
$legs = 'LEG303A', 'LEG303B', 'LEG303C'

function Invoke-Checked([string]$what, [scriptblock]$cmd) {
    $out = & $cmd *>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE): $($out | Select-Object -Last 5 | Out-String)" }
    $out
}

function Test-Stamp([string]$leg, [string]$stamp) {
    if (-not $stamp -or $stamp -match 'dirty|none') { throw "$leg stamp unusable: '$stamp'" }
}

# A mistyped switch would otherwise fall through to a full phase 1 staging.
if ($args) { throw "unknown arguments: $($args -join ' ')" }

# Test overrides must never pass silently in a real staging.
foreach ($ov in @(@('CORE303_TREE_ROOT', 'clean-tree git check'), @('CORE303_PLINK', 'plink executable'),
        @('CORE303_PSCP', 'pscp executable'))) {
    $val = [Environment]::GetEnvironmentVariable($ov[0])
    if ($val) { "WARNING: $($ov[0]) set - $($ov[1]) -> $val" }
}

$phase2Args = $Ks3Rerun -or $Phase2 -or $P2Only -or $PushPi -or $Board -or $Date -or $ResultsRoot -or
    $StagedRecord -or $PSBoundParameters.ContainsKey('PiHost')
if ($phase2Args) {
    if ($PushPi -and -not ($Phase2 -or $P2Only)) { throw "-PushPi needs -Phase2 or -P2Only" }
    if (([int][bool]$Ks3Rerun + [int][bool]$Phase2 + [int][bool]$P2Only) -ne 1) {
        throw "give exactly one of -Ks3Rerun, -Phase2, -P2Only"
    }
    if ($Ks3Rerun) {
        if ($Board -or $Date -or $ResultsRoot -or $PSBoundParameters.ContainsKey('PiHost')) {
            throw "-Board, -Date, -ResultsRoot and -PiHost are for -Phase2 and -P2Only"
        }
    }
    else {
        if ($StagedRecord) { throw "-StagedRecord is for -Ks3Rerun" }
        if ($Board -notmatch '^[A-Za-z0-9_]+$') { throw "-Board must be letters, digits or _ (got '$Board')" }
        if ($Date -notmatch '^\d{4}-\d{2}-\d{2}$') { throw "-Date must be YYYY-MM-DD (got '$Date')" }
        if ($PiHost -notmatch '^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$') { throw "bad -PiHost '$PiHost'" }
    }

    $piDir = Join-Path $root 'tests\core303\pi'
    $buildDir = Join-Path $root 'build\core303'
    $framesDir = Join-Path $buildDir 'frames'
    $resRoot = if ($ResultsRoot) { (Resolve-Path -LiteralPath $ResultsRoot).Path }
    else { Join-Path $root 'tests\core303\results' }
    # Tests substitute recording fakes; the run sheet commands always name plink and pscp.
    $plinkExe = if ($env:CORE303_PLINK) { $env:CORE303_PLINK } else { 'plink' }
    $pscpExe = if ($env:CORE303_PSCP) { $env:CORE303_PSCP } else { 'pscp' }

    function Show-Path([string]$p) { if ($p.StartsWith("$root\")) { $p.Substring($root.Length + 1) } else { $p } }
    function Get-Sha([string]$p) { (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower() }
    function Write-Lf([string]$path, [string[]]$lines) { [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n")) }
    function Format-Cmd([string]$exe, [string[]]$a) {
        (@($exe) + @($a | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })) -join ' '
    }

    # Only the folders this mode writes; logs anywhere below them refuse the run.
    function Assert-NoLogs([string[]]$folders) {
        $raw = @(foreach ($f in $folders) {
                $d = Join-Path $sd $f
                if (Test-Path -LiteralPath $d) {
                    Get-ChildItem -LiteralPath $d -File -Recurse -Force |
                        Where-Object { $_.Name -like '*.LOG' -or $_.Name -like 'NXBENCH*.TXT' }
                }
            })
        if ($raw) { throw "ingest first: $(($raw | ForEach-Object { $_.FullName.Substring($sd.Length + 1) }) -join ', ')" }
        foreach ($f in $folders) {
            $d = Join-Path $sd $f
            if ((Test-Path -LiteralPath $d) -and (Get-ChildItem -LiteralPath $d -Directory -Force)) {
                throw "sd\$f holds a subfolder: move it out by hand first"
            }
        }
    }

    function Test-Link([string]$p) {
        (Test-Path -LiteralPath $p) -and
        ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
    }
    function New-Scratch([string]$name) {
        $outDir = Join-Path $root 'tests\out'
        $w = Join-Path $outDir $name
        if ((Split-Path -Parent $w) -ne $outDir) { throw "bad scratch path $w" }
        foreach ($p in $outDir, $w) { if (Test-Link $p) { throw "$p is a link - clear it by hand" } }
        if (Test-Path -LiteralPath $w) {
            if (Get-ChildItem -LiteralPath $w -Recurse -Force -Attributes ReparsePoint) { throw "link under $w - clear it by hand" }
            Get-ChildItem -LiteralPath $w -Force | Remove-Item -Recurse -Force
        }
        New-Item -ItemType Directory -Force $w | Out-Null
        $w
    }

    # Leg folders hold files only (Assert-NoLogs refused subfolders): replace them file by file.
    function Write-Legs([string]$from, [string[]]$names) {
        foreach ($l in $names) {
            $dest = Join-Path $sd $l
            if ((Split-Path -Parent $dest) -ne $sd) { throw "bad leg path $dest" }
            New-Item -ItemType Directory -Force $dest | Out-Null
            Get-ChildItem -LiteralPath $dest -File -Force | Remove-Item -Force
            Get-ChildItem -LiteralPath (Join-Path $from $l) -File | Copy-Item -Destination $dest -Force
            "staged sd\$l\ ($(@(Get-ChildItem -LiteralPath $dest -File).Count) files)"
        }
    }

    function Get-Py([string]$what, [string[]]$pyArgs) {
        $out = @(& python -B @pyArgs 2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE): $($out | Select-Object -Last 5 | Out-String)" }
        $out
    }
    function Get-Hash12([string]$what, [string[]]$pyArgs) {
        $h = Get-Py $what $pyArgs | Select-Object -Last 1
        if ($h -notmatch '^[0-9a-f]{12}$') { throw "$what gave '$h'" }
        $h
    }
    function Test-Staged([string]$dir) {
        $v = @(& python -B "$root\tests\core303\ingest.py" --verify-staged $dir 2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) {
            $v | ForEach-Object { "verify-staged: $_" }
            throw "$(Show-Path $dir) fails its MANIFEST, nothing written"
        }
    }

    # -Ks3Rerun: phase 1's KS1 binaries, byte-identical, into sd\LEG303A3, B3 and C3.
    if ($Ks3Rerun) {
        $rec = if ($StagedRecord) { (Resolve-Path -LiteralPath $StagedRecord).Path }
        else { Join-Path $root 'tests\core303\results\2026-11-14-ks1-staged' }
        if ((Split-Path -Leaf $rec) -notmatch '^(\d{4}-\d{2}-\d{2}-[a-z0-9_]+)-staged$') { throw "not a staged record: $rec" }
        $rerunOf = $Matches[1]
        $rlegs = 'LEG303A3', 'LEG303B3', 'LEG303C3'
        Assert-NoLogs $rlegs
        $man = @(foreach ($line in Get-Content -LiteralPath (Join-Path $rec 'MANIFEST.txt')) {
                if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
                $p = -split $line
                if ($p.Count -ne 3 -or $p[1] -notmatch '^(LEG303[ABC])/([^/]+)$') { throw "bad MANIFEST line: $line" }
                $here = Join-Path $rec ($p[1] -replace '/', '\')
                # As verify_staged: the record's copy when present, else the tracked path.
                $src = if ($p[2] -eq 'here' -or (Test-Path -LiteralPath $here)) { $here }
                else { Join-Path $root ($p[2] -replace '/', '\') }
                [pscustomobject]@{ Sha = $p[0]; Rel = $p[1]; Leg = "$($Matches[1])3"; Name = $Matches[2]
                    Src = $src; Label = if ($src -eq $here) { Show-Path $here } else { $p[2] } }
            })
        if ($WhatIf) {
            "MODE -Ks3Rerun from $(Show-Path $rec)\"
            "STEP 0: refuse (ingest first) if sd\LEG303A3, B3 or C3 holds a .LOG or NXBENCH*.TXT"
            "STEP 1: python -B tests\core303\ingest.py --verify-staged $(Show-Path $rec)"
            "STEP 2: copy each MANIFEST file to its leg under tests\out\core303-ks3rerun\, re-check every sha256"
            "STEP 3: GATES.TXT = the original bytes plus rerun_of: $rerunOf"
            foreach ($l in $rlegs) {
                "WRITE sd\$l\"
                foreach ($m in @($man | Where-Object { $_.Leg -eq $l })) { "  $l/$($m.Name) <- $($m.Label)" }
            }
            "WRITE sd\LEG303R.TXT"
            return
        }
        Test-Staged $rec
        $rw = New-Scratch 'core303-ks3rerun'
        foreach ($l in $rlegs) { New-Item -ItemType Directory -Force (Join-Path $rw $l) | Out-Null }
        foreach ($m in $man) {
            $dst = Join-Path $rw "$($m.Leg)\$($m.Name)"
            Copy-Item -LiteralPath $m.Src -Destination $dst
            if ((Get-Sha $dst) -ne $m.Sha) { throw "$($m.Rel) changed while copying" }
            if ($m.Name -eq 'GATES.TXT') {
                $b = [IO.File]::ReadAllBytes($dst)
                if ($b.Length -eq 0 -or $b[-1] -ne 10) { throw "$($m.Rel) does not end in LF" }
                [IO.File]::WriteAllBytes($dst, [byte[]]($b + [Text.Encoding]::ASCII.GetBytes("rerun_of: $rerunOf`n")))
            }
        }
        foreach ($l in $rlegs) { if (-not (Test-Path -LiteralPath "$rw\$l\GATES.TXT")) { throw "$l has no GATES.TXT" } }
        Write-Lf "$rw\LEG303R.TXT" @(
            "LEG303A3  CORE303.NEX     standalone bench, $rerunOf binary; writes CORE303.LOG beside itself",
            "LEG303B3  NEXTDAAD.NEX    BENCH interpreter, fixture GAME.DDB, $rerunOf binary; writes BENCH303.LOG",
            "LEG303C3  NEXTDAAD.NEX    NXB video bench, NXB0-9.BIN payloads, $rerunOf binary",
            'Each folder is complete: copy it to the card root and launch its NEX from inside it.')
        Write-Legs $rw $rlegs
        Copy-Item -LiteralPath "$rw\LEG303R.TXT" -Destination (Join-Path $sd 'LEG303R.TXT') -Force
        "staged sd\LEG303R.TXT"
        return
    }

    # -Phase2 / -P2Only
    $bl = $Board.ToLower()
    $bu = $Board.ToUpper()
    $outLegs = @(if ($Phase2) { 'LEG303P0', 'LEG303P2', 'LEG303P3', 'LEG303P4' } else { "LEG303P2$bu" })
    $piLegs = @(if ($Phase2) { 'P0', 'P2', 'P3', 'P4' } else { 'P2' })
    $pw = Join-Path $root "tests\out\$(if ($Phase2) { 'core303-phase2' } else { 'core303-p2only' })"
    $pt = Join-Path $pw 'pi'
    $recName = "$Date-$bl-staged"
    $recDest = Join-Path $resRoot $recName
    $recPart = Join-Path $resRoot ".$recName.partial"
    Assert-NoLogs $outLegs
    if ($Phase2 -and (Test-Path -LiteralPath $recDest)) {
        throw "staged record exists, never overwritten: $(Show-Path $recDest)"
    }
    if ($Phase2 -and (Test-Path -LiteralPath $recPart)) {
        throw "stale partial record from a failed run, remove it by hand: $(Show-Path $recPart)"
    }
    # GATES bundle:/frames: must name bytes git holds. CORE303_TREE_ROOT (tests) swaps the tree.
    $treeRoot = if ($env:CORE303_TREE_ROOT) { $env:CORE303_TREE_ROOT } else { $root }
    $treePaths = 'tests/core303/pi', 'tests/core303/stage.ps1'
    if (-not $WhatIf) {
        $dirty = git -C $treeRoot status --porcelain -- @treePaths
        if ($LASTEXITCODE -ne 0) { throw "git status failed in $treeRoot" }
        if ($dirty) { throw "uncommitted changes under $($treePaths -join ', '): commit them first" }
    }
    $b12 = Get-Hash12 'bundle hash' @('-c', 'import sys; sys.path.insert(0, sys.argv[1]); import bundle; print(bundle.bundle_hash(sys.argv[1]))', $piDir)
    # Writes '<path> <sha256>' lines (the input of bundle.py's hash) and checks they hash to it.
    $pyLst = "import sys, hashlib, pathlib as P; sys.path.insert(0, sys.argv[1]); import bundle as B; " +
    "k, r, o = sys.argv[2], P.Path(sys.argv[3]), P.Path(sys.argv[4]); " +
    "n = [x.strip() for x in (r / 'BUNDLE.txt').read_text(encoding='ascii').splitlines() if x.strip()] if k == 'bundle' " +
    "else [f.relative_to(r).as_posix() for f in r.rglob('*') if f.is_file()]; " +
    "w = B.bundle_hash(r) if k == 'bundle' else B.dir_hash(r); " +
    "t = ''.join('%s %s\n' % (x, hashlib.sha256((r / x).read_bytes()).hexdigest()) for x in sorted(n)); " +
    "assert hashlib.sha256(t.encode('ascii')).hexdigest()[:12] == w; o.write_bytes(t.encode('ascii')); print(w)"

    # Pi side: everything under /root/core303/<bundle12>/, never a remote delete.
    $rb = "/root/core303/$b12"
    $names = @(Get-Content -LiteralPath "$piDir\BUNDLE.txt" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $pushSrc = @($names | Where-Object { $_ -notmatch '/' }) + @('BUNDLE.txt') +
    @($names | Where-Object { $_ -match '/' } | ForEach-Object { ($_ -split '/')[0] } | Select-Object -Unique) +
    @('frames') + @(if ($Phase2) { 'map' })
    $maps = @(if ($Phase2) { "$rb/map/PI303.MAP", "$rb/map/PI303V.MAP" })
    $check = "cd $rb && python3 -c 'import bundle,sys,hashlib,pathlib; a=sys.argv; " +
    "print(bundle.bundle_hash(a[1]), bundle.dir_hash(a[2]), *[hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in a[3:]])' " +
    (@($rb, "$rb/frames") + $maps -join ' ')
    $gcc = "cd $rb && gcc -O2 -std=c99 -Wall -Wextra -o spi303 c/core303pi.c c/spi303.c && " +
    "(test -f /usr/include/jpeglib.h && gcc -O2 -Ic -o prep303 c/prep303.c c/core303pi.c -ljpeg || " +
    "gcc -O2 -Ic -o prep303 c/prep303.c c/core303pi.c -DNO_JPEG)"
    $steps = @(
        [pscustomobject]@{ Exe = $plinkExe; Name = 'plink'; Cwd = $null
            Args = @('-batch', $PiHost, ('mkdir -p ' + (($piLegs | ForEach-Object { "$rb/out/$_" }) -join ' '))) },
        [pscustomobject]@{ Exe = $pscpExe; Name = 'pscp'; Cwd = $pt
            Args = @('-batch', '-q', '-r') + $pushSrc + @("${PiHost}:$rb/") },
        [pscustomobject]@{ Exe = $plinkExe; Name = 'plink'; Cwd = $null; Args = @('-batch', $PiHost, $check) },
        [pscustomobject]@{ Exe = $plinkExe; Name = 'plink'; Cwd = $null; Args = @('-batch', $PiHost, $gcc) })
    foreach ($s in $steps) {
        $show = Format-Cmd $s.Name $s.Args
        if ($s.Cwd) { $show += " (from $(Show-Path $s.Cwd))" }
        $s | Add-Member -NotePropertyName Show -NotePropertyValue $show
    }
    $runTool = @{
        P0 = "python3 $rb/pi303_probe.py --out $rb/out/P0 --bundle $b12"
        P2 = "python3 $rb/pi303_prep.py --frames $rb/frames --out $rb/out/P2 --bundle $b12"
        P3 = "python3 $rb/pi303_spi.py --map $rb/map/PI303.MAP --tool $rb/spi303 --out $rb/out/P3 --bundle $b12"
        P4 = "python3 $rb/pi303_video.py --map $rb/map/PI303V.MAP --spi-log $rb/out/P3/SPI.LOG --frames $rb/frames " +
        "--tool $rb/spi303 --out $rb/out/P4 --bundle $b12"
    }
    # Each run first removes only that leg's own earlier logs, by exact name.
    $legLogs = @{ P0 = @('PROBE.LOG'); P2 = @('PREP.LOG'); P3 = @('SPI.LOG', 'PI_PI303.LOG')
        P4 = @('VIDEO.LOG', 'PI_PI303V.LOG')
    }
    # The run sheet copies these verbatim: one plink per leg, then the pscp fetch into its sd folder.
    function Show-RunFetch {
        foreach ($p in $piLegs) {
            $legDir = if ($P2Only) { "LEG303P2$bu" } else { "LEG303$p" }
            $rm = 'rm -f ' + (($legLogs[$p] | ForEach-Object { "$rb/out/$p/$_" }) -join ' ')
            "RUN ${p}: plink -batch $PiHost `"cd $rb && $rm && $($runTool[$p])`""
            "FETCH ${p}: pscp -batch ${PiHost}:$rb/out/$p/* sd\$legDir\"
        }
    }

    if ($WhatIf) {
        "MODE $(if ($Phase2) { '-Phase2' } else { '-P2Only' }) board=$bl date=$Date"
        "STEP 0: refuse (ingest first) if $(($outLegs | ForEach-Object { "sd\$_" }) -join ', ') holds a .LOG or NXBENCH*.TXT"
        if ($Phase2) { "STEP 0: refuse if $(Show-Path $recDest)\ or $(Show-Path $recPart)\ exists" }
        "STEP 0: refuse if git status --porcelain -- $($treePaths -join ' ') prints anything"
        "STEP 1: bundle $b12 over tests\core303\pi\BUNDLE.txt"
        if ($Phase2) {
            "STEP 2: tests\core303\pi\next\build.ps1 (no -AllowDirty), stamp checked"
            "WRITE build\core303\PI303.NEX PI303.MAP PI303V.NEX PI303V.MAP"
        }
        "STEP 3: frames.make into build\core303\frames\ (old F*.png/jpg/raw and SOURCE.txt removed first)"
        "WRITE build\core303\frames\"
        "STEP 4: assemble $(($outLegs) -join ', ') with GATES.TXT under $(Show-Path $pw)\"
        if ($Phase2) {
            "STEP 5: assemble the staged record and MANIFEST.txt there, python -B tests\core303\ingest.py --verify-staged on it"
        }
        if ($PushPi) {
            "STEP 6: copy the bundle, frames$(if ($Phase2) { ' and MAPs' }) to $(Show-Path $pt)\, re-check both hashes, then:"
            foreach ($s in $steps) { "REMOTE $($s.Show)" }
        }
        if ($Phase2) { "WRITE $(Show-Path $recDest)\ (as .$recName.partial, renamed when verified)" }
        foreach ($l in $outLegs) { "WRITE sd\$l\" }
        if ($Phase2) { "WRITE sd\LEG303P.TXT" }
        if ($PushPi) { Show-RunFetch }
        return
    }

    $null = New-Scratch (Split-Path -Leaf $pw)
    if ($Phase2) {
        $o = Invoke-Checked 'PI303/PI303V build' { & "$piDir\next\build.ps1" }
        $o
        $stamp = ($o | Where-Object { $_ -match '^stamp: (\S+)$' } | Select-Object -First 1) -replace '^stamp: ', ''
        Test-Stamp 'PI303' $stamp
    }

    # Frames: only the generator's own files may be replaced.
    if (Test-Path -LiteralPath $framesDir) {
        foreach ($i in Get-ChildItem -LiteralPath $framesDir -Force) {
            if ($i.PSIsContainer -or $i.Name -notmatch '^(F\d{3}\.(png|jpg|raw)|SOURCE\.txt)$') {
                throw "unexpected $($i.Name) in build\core303\frames - remove it by hand"
            }
        }
        Get-ChildItem -LiteralPath $framesDir -File -Force | Remove-Item -Force
    }
    Get-Py 'frames.make' @('-c', 'import sys; sys.path.insert(0, sys.argv[1]); import frames; frames.make(sys.argv[2])', $piDir, $framesDir) | Out-Null
    $fh = Get-Hash12 'frames hash' @('-c', $pyLst, $piDir, 'frames', $framesDir, "$pw\FRAMES.lst")
    if ((Get-Hash12 'bundle list' @('-c', $pyLst, $piDir, 'bundle', $piDir, "$pw\BUNDLE.lst")) -ne $b12) {
        throw "tests\core303\pi changed during staging"
    }
    "bundle: $b12"
    "frames: $fh"

    $gates = @("bundle: $b12", "frames: $fh", "board: $bl", "sitting: $Date", "built: $(Get-Date -Format 'yyyy-MM-dd')")
    foreach ($l in $outLegs) { New-Item -ItemType Directory -Force "$pw\$l" | Out-Null }
    if ($P2Only) { Write-Lf "$pw\$($outLegs[0])\GATES.TXT" $gates }
    else {
        foreach ($l in 'LEG303P0', 'LEG303P2') { Write-Lf "$pw\$l\GATES.TXT" $gates }
        # NEX and MAP travel together: GATES pins both, the Pi gets this MAP.
        foreach ($pair in @(@('LEG303P3', 'PI303'), @('LEG303P4', 'PI303V'))) {
            $l, $n = $pair
            Copy-Item -LiteralPath "$buildDir\$n.NEX" -Destination "$pw\$l\$n.NEX"
            Copy-Item -LiteralPath "$buildDir\$n.MAP" -Destination "$pw\$l\$n.MAP"
            $mapKeys = @(foreach ($m in Get-Content -LiteralPath "$pw\$l\$n.MAP") {
                    if ($m -cnotmatch '^([a-z][a-z0-9_]*)=([0-9A-F]+)$') { throw "bad $n.MAP line: $m" }
                    "map_$($Matches[1]): $($Matches[2])"
                })
            Write-Lf "$pw\$l\GATES.TXT" (@("stamp: $stamp") + $gates +
                @("nex_sha256: $(Get-Sha "$pw\$l\$n.NEX")", "map_sha256: $(Get-Sha "$pw\$l\$n.MAP")") + $mapKeys)
        }
        Write-Lf "$pw\LEG303P.TXT" @(
            'LEG303P0  (no NEX)      P0 board gate; the Pi probe log is fetched here',
            'LEG303P2  (no NEX)      P2 Pi prep bench; the Pi log is fetched here',
            'LEG303P3  PI303.NEX     P3 SPI bench; writes PI303.LOG beside itself, Pi logs fetched here',
            'LEG303P4  PI303V.NEX    P4 Pi video; writes PI303V.LOG beside itself, Pi logs fetched here',
            "bundle $b12  frames $fh",
            'LEG303P3 and LEG303P4 are complete: copy each to the card root and launch its NEX from inside it.')

        # Staged record: frames by hash (FRAMES.lst), regenerated by frames.make, never copied.
        $sr = Join-Path $pw "staged\$recName"
        foreach ($l in $outLegs) {
            New-Item -ItemType Directory -Force "$sr\$l" | Out-Null
            Get-ChildItem -LiteralPath "$pw\$l" -File | Copy-Item -Destination "$sr\$l"
        }
        Copy-Item -LiteralPath "$pw\BUNDLE.lst", "$pw\FRAMES.lst" -Destination $sr
        $ver = -split (Get-Py 'Pillow/numpy versions' @('-c', 'import PIL, numpy; print(PIL.__version__, numpy.__version__)') | Select-Object -Last 1)
        [string[]]$rels = @(Get-ChildItem -LiteralPath $sr -File -Recurse | ForEach-Object { $_.FullName.Substring($sr.Length + 1).Replace('\', '/') })
        [Array]::Sort($rels, [StringComparer]::Ordinal)
        Write-Lf "$sr\MANIFEST.txt" (@(
                "# Every file staged for the $bu sitting $Date (logs excluded), sha256 and where its bytes live.",
                "# 'here' = preserved in this folder; otherwise the tracked repo path holding identical bytes.",
                "# bundle $b12 = first 12 hex of sha256(BUNDLE.lst): tests/core303/pi files named by BUNDLE.txt.",
                "# frames $fh = first 12 hex of sha256(FRAMES.lst); not copied: tests/core303/pi/frames.py",
                "# make(n=120) regenerates them (Pillow $($ver[0]), numpy $($ver[1])). The bytes are as generated",
                "# on the staging PC: frames.py writes SOURCE.txt with the platform line ending.") +
            @($rels | ForEach-Object { "$(Get-Sha (Join-Path $sr $_))  $_  here" }))
        Test-Staged $sr
    }

    if ($PushPi) {
        New-Item -ItemType Directory -Force $pt | Out-Null
        foreach ($n in @($names) + @('BUNDLE.txt')) {
            $dst = Join-Path $pt ($n -replace '/', '\')
            New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
            Copy-Item -LiteralPath (Join-Path $piDir ($n -replace '/', '\')) -Destination $dst
        }
        New-Item -ItemType Directory -Force "$pt\frames" | Out-Null
        Get-ChildItem -LiteralPath $framesDir -File | Copy-Item -Destination "$pt\frames"
        $expect = @($b12, $fh)
        if ($Phase2) {
            New-Item -ItemType Directory -Force "$pt\map" | Out-Null
            Copy-Item -LiteralPath "$pw\LEG303P3\PI303.MAP", "$pw\LEG303P4\PI303V.MAP" -Destination "$pt\map"
            $expect += (Get-Sha "$pt\map\PI303.MAP"), (Get-Sha "$pt\map\PI303V.MAP")
        }
        if ((Get-Hash12 'push bundle' @('-c', $pyLst, $piDir, 'bundle', $pt, "$pw\push-bundle.lst")) -ne $b12 -or
            (Get-Hash12 'push frames' @('-c', $pyLst, $piDir, 'frames', "$pt\frames", "$pw\push-frames.lst")) -ne $fh) {
            throw "push tree does not match bundle $b12 / frames $fh"
        }
        foreach ($s in $steps) {
            "REMOTE $($s.Show)"
            if ($s.Cwd) { Push-Location -LiteralPath $s.Cwd }
            try { $out = @(& $s.Exe @($s.Args) 2>&1 | ForEach-Object { "$_" }) }
            finally { if ($s.Cwd) { Pop-Location } }
            if ($LASTEXITCODE -ne 0) { throw "remote step failed (exit $LASTEXITCODE): $($out | Select-Object -Last 5 | Out-String)" }
            $out
            if ($s.Args[-1] -eq $check) {
                $got = ($out | Select-Object -Last 1) -replace '\s+', ' '
                if ($got -ne ($expect -join ' ')) {
                    throw "remote hash check failed, nothing staged: expected '$($expect -join ' ')' got '$got' (stale files under $rb/ must be cleared by hand)"
                }
            }
        }
    }

    # Every check passed: the record lands whole (partial, verify, rename), then sd\.
    if ($Phase2) {
        if ((Test-Path -LiteralPath $recDest) -or (Test-Path -LiteralPath $recPart)) {
            throw "$(Show-Path $recDest) or its .partial appeared during staging"
        }
        Copy-Item -LiteralPath $sr -Destination $recPart -Recurse
        Test-Staged $recPart
        Move-Item -LiteralPath $recPart -Destination $recDest
        "staged $(Show-Path $recDest)\"
    }
    Write-Legs $pw $outLegs
    if ($Phase2) {
        Copy-Item -LiteralPath "$pw\LEG303P.TXT" -Destination (Join-Path $sd 'LEG303P.TXT') -Force
        "staged sd\LEG303P.TXT"
    }
    if ($PushPi) { Show-RunFetch }
    return
}

# Raw logs copied back from the card would be emptied by step 7.
$raw = @(Get-ChildItem -Path (Join-Path $sd 'LEG303*') -Directory -ErrorAction SilentlyContinue |
    Get-ChildItem -File | Where-Object { $_.Name -like '*.LOG' -or $_.Name -like 'NXBENCH*.TXT' })
if ($raw) { throw "ingest first: $(($raw | ForEach-Object { "$($_.Directory.Name)\$($_.Name)" }) -join ', ')" }

if ($WhatIf) {
    "STEP 0: refuse (ingest first) if a LEG303 folder holds a .LOG or NXBENCH*.TXT"
    "STEP 1: tests\core303\bench\build.ps1 (no -AllowDirty), copy CORE303.NEX to LEG303A"
    "STEP 2: python tests\check_quiet_decode.py"
    "STEP 2: python tests\check_quiet_decode.py --bench"
    "STEP 3: build.ps1 -Bench, copy nextdaad.nex to LEG303B, compile fixture, stage fixture assets"
    "STEP 4: tests\build-tests.ps1 -NxBench (regenerates sd\NXBENCH\ itself), copy all but nextdaad.nex to LEG303C"
    "STEP 5: build.ps1 -BenchQuiet, copy nextdaad.nex to LEG303C"
    "STEP 6: write GATES.TXT per leg"
    "STEP 7: refuse if any gate failed or any stamp is dirty"
    "WRITE sd\LEG303A\"
    "WRITE sd\LEG303B\"
    "WRITE sd\LEG303C\"
    "WRITE sd\LEG303.TXT"
    "STEP 8: build.ps1 -Release"
    return
}

function Get-Gate([string]$what, [string[]]$checkArgs) {
    $out = & python -B "$root\tests\check_quiet_decode.py" @checkArgs *>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $line = $out | Where-Object { $_ -match '^(OK|FAIL)\b' } | Select-Object -Last 1
    if ($code -ne 0 -or -not $line -or $line -notmatch '^OK') {
        throw "gate '$what' failed (exit $code): $line"
    }
    $line
}

function Get-SrcStamp {
    $h = git -C $root log -1 --format=%h -- src
    if ($LASTEXITCODE -ne 0 -or -not $h) { throw "no commit touches src\" }
    if (git -C $root status --porcelain -- src) { return "$h-dirty" }
    $h
}

$tracked = 'src', 'tests/core303/bench', 'tests/core303/fixture', 'tests/core303/stage.ps1',
    'tests/check_quiet_decode.py'
if (git -C $root status --porcelain -- @tracked) {
    throw "uncommitted changes under $($tracked -join ', '): commit them first"
}
if (Get-Process CSpect -ErrorAction SilentlyContinue) { throw "CSpect is running - close it first" }

# Scratch assembly area: an exact path under tests\out.
if ((Split-Path -Parent $work) -ne (Join-Path $root 'tests\out')) { throw "bad scratch path $work" }
if (Test-Path -LiteralPath $work) { Get-ChildItem -LiteralPath $work -Force | Remove-Item -Recurse -Force }
foreach ($l in $legs) { New-Item -ItemType Directory -Force (Join-Path $work $l) | Out-Null }
$nexBuild = Join-Path $root 'build\nextdaad.nex'

# 1. standalone bench
$o1 = Invoke-Checked 'standalone bench build' { & "$root\tests\core303\bench\build.ps1" }
$o1
$stampA = ($o1 | Where-Object { $_ -match '^stamp: (\S+)$' } | Select-Object -First 1) -replace '^stamp: ', ''
Test-Stamp 'LEG303A' $stampA
Copy-Item "$root\build\core303\CORE303.NEX" "$work\LEG303A\CORE303.NEX" -Force

# 2. gates
$quiet = Get-Gate 'quiet decode' @()
$bench = Get-Gate 'bench decode' @('--bench')
"quiet_check: $quiet"
"bench_check: $bench"

# 3. BENCH interpreter + fixture
$stampB = Get-SrcStamp
Test-Stamp 'LEG303B' $stampB
Invoke-Checked 'build.ps1 -Bench' { & "$root\build.ps1" -Bench } | Select-Object -Last 3
Copy-Item $nexBuild "$work\LEG303B\NEXTDAAD.NEX" -Force

$ndrc = if ($env:NEXTDAAD_NDRC) { $env:NEXTDAAD_NDRC } else { Join-Path $root 'authoring-kit\lib\ndrc.exe' }
if (-not (Test-Path -LiteralPath $ndrc)) { throw "no ndrc at $ndrc" }
$fix = Join-Path $work 'fixture-build'
New-Item -ItemType Directory -Force $fix | Out-Null
Copy-Item "$PSScriptRoot\fixture\bench.dsf" "$fix\BENCH.DSF" -Force
Push-Location $fix
try {
    Invoke-Checked 'ndrc fixture' { & $ndrc nextdaad EN BENCH.DSF BENCH.DDB -v3 -nxtext } | Select-Object -Last 3
}
finally { Pop-Location }
Copy-Item "$fix\BENCH.DDB" "$work\LEG303B\GAME.DDB" -Force
if (Test-Path "$fix\0.XMB") { Copy-Item "$fix\0.XMB" "$work\LEG303B\0.XMB" -Force }
foreach ($line in Get-Content "$PSScriptRoot\fixture\SOURCES.txt") {
    if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
    $p = $line -split '\s+'
    if ($p.Count -ne 3 -or $p[1] -ne '<-') { throw "bad SOURCES.txt line: $line" }
    $src = Join-Path $root ($p[2] -replace '/', '\')
    if (-not (Test-Path -LiteralPath $src)) { throw "fixture source missing: $($p[2])" }
    Copy-Item $src "$work\LEG303B\$($p[0])" -Force
}
if (Get-ChildItem "$work\LEG303B" | Where-Object { $_.Name -match '^GAME\.(AKY|AYS|SFB)$' }) {
    throw "LEG303B holds GAME.AKY/AYS/SFB"
}

# 4. NXB payloads
Invoke-Checked 'build-tests.ps1 -NxBench' { & "$root\tests\build-tests.ps1" -NxBench } | Select-Object -Last 3
Get-ChildItem -LiteralPath "$sdReal\NXBENCH" -File | Where-Object { $_.Name -ne 'NEXTDAAD.NEX' } |
    ForEach-Object { Copy-Item $_.FullName "$work\LEG303C\$($_.Name)" -Force }

# 5. quiet interpreter
$stampC = Get-SrcStamp
Test-Stamp 'LEG303C' $stampC
Invoke-Checked 'build.ps1 -BenchQuiet' { & "$root\build.ps1" -BenchQuiet } | Select-Object -Last 3
Copy-Item $nexBuild "$work\LEG303C\NEXTDAAD.NEX" -Force

# 6. GATES.TXT from the staged NEX files
$stamps = @{ LEG303A = $stampA; LEG303B = $stampB; LEG303C = $stampC }
$nexName = @{ LEG303A = 'CORE303.NEX'; LEG303B = 'NEXTDAAD.NEX'; LEG303C = 'NEXTDAAD.NEX' }
$built = Get-Date -Format 'yyyy-MM-dd'
foreach ($l in $legs) {
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath "$work\$l\$($nexName[$l])").Hash.ToLower()
    $g = @("stamp: $($stamps[$l])", "built: $built", "quiet_check: $quiet", "bench_check: $bench", "nex_sha256: $sha")
    if ($l -eq 'LEG303B') {
        $g += "ddb_sha256: $((Get-FileHash -Algorithm SHA256 -LiteralPath "$work\$l\GAME.DDB").Hash.ToLower())"
    }
    [IO.File]::WriteAllText("$work\$l\GATES.TXT", (($g -join "`n") + "`n"))
}
$idx = @(
    'LEG303A  CORE303.NEX     standalone bench; writes CORE303.LOG beside itself',
    'LEG303B  NEXTDAAD.NEX    BENCH interpreter, fixture GAME.DDB; writes BENCH303.LOG',
    'LEG303C  NEXTDAAD.NEX    NXB video bench, NXB0-9.BIN payloads',
    'Each folder is complete: copy it to the card root and launch its NEX from inside it.'
)
[IO.File]::WriteAllText("$work\LEG303.TXT", (($idx -join "`n") + "`n"))

# 7. every gate and stamp passed: only now write sd\
foreach ($l in $legs) {
    $dest = Join-Path $sd $l
    if ((Split-Path -Parent $dest) -ne $sd) { throw "bad leg path $dest" }
    New-Item -ItemType Directory -Force $dest | Out-Null
    Get-ChildItem -LiteralPath $dest -Force | Remove-Item -Recurse -Force
    Copy-Item "$work\$l\*" $dest -Recurse -Force
    "staged sd\$l\ ($((Get-ChildItem $dest | Measure-Object).Count) files)"
}
Copy-Item "$work\LEG303.TXT" "$sd\LEG303.TXT" -Force
"staged sd\LEG303.TXT"

# 8. leave a Release build behind
Invoke-Checked 'build.ps1 -Release' { & "$root\build.ps1" -Release } | Select-Object -Last 2
