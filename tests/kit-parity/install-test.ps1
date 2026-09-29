# Clean-container install test: a bare Ubuntu image plus the Linux kit zip, set
# up as manual/getting-started.md "Linux setup" says, must build. Exit 0/1/2.
# -BuildZip cuts the zip from HEAD as release-kit.yml does (kit-files.ps1 | zip -@).
param(
    [string]$Zip = '',
    [ValidateSet('1', '2', '3', '4', 'all')][string]$Pass = 'all',
    [ValidateSet('', 'ubuntu:22.04', 'ubuntu:24.04')][string]$Base = '',
    [switch]$BuildZip,
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $root 'authoring-kit/lib/kitplatform.ps1')
. (Join-Path $root 'authoring-kit/lib/kittools.ps1')
$pins = Read-ToolVersions (Join-Path $root 'authoring-kit/lib')
$work = [IO.Path]::GetFullPath((Join-Path $root 'tests/out/install-test'))
New-Item -ItemType Directory -Force $work | Out-Null
if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) { Write-Host 'install-test: docker not found'; exit 2 }
function Sha([string]$p) { $h = [Security.Cryptography.SHA256]::Create(); try { return (-join ($h.ComputeHash([IO.File]::ReadAllBytes($p)) | ForEach-Object { $_.ToString('x2') })) } finally { $h.Dispose() } }
# LF only: the scripts run under sh in the container.
function Write-Lf([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, (($Text -replace "`r", '').TrimEnd() + "`n"), (New-Object Text.UTF8Encoding $false))
}
function Invoke-Docker([string[]]$DockerArgs, [string]$Log) {
    $lines = New-Object System.Collections.Generic.List[string]
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker @DockerArgs 2>&1 | ForEach-Object { $s = "$_"; Write-Host $s; $lines.Add($s) }; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $eap }
    [IO.File]::WriteAllLines($Log, $lines.ToArray())
    return $code
}

$dryZip = Join-Path $work 'NextDAAD-AuthoringKit-dryrun-linux.zip'
if ($BuildZip) {
    # git archive keeps the index modes (tar.umask 022 = checkout's 0755/0644);
    # the Windows working tree has none. autocrlf off matches a Linux checkout.
    $cut = Join-Path $work 'zipcut'
    if (Test-Path -LiteralPath $cut) { Remove-Item -LiteralPath $cut -Recurse -Force }
    New-Item -ItemType Directory -Force $cut | Out-Null
    $dirty = @(& git -C $root status --porcelain -- authoring-kit scripts/kit-files.ps1)
    if ($dirty.Count) { Write-Host 'install-test: WARNING uncommitted kit changes are not in the zip (cut from HEAD)' }
    Write-Host "install-test: cutting the Linux zip from HEAD $(& git -C $root rev-parse --short HEAD)"
    & git -C $root -c core.autocrlf=false -c tar.umask=022 archive --format=tar -o (Join-Path $cut 'kitsrc.tar') HEAD authoring-kit scripts/kit-files.ps1
    if ($LASTEXITCODE -ne 0) { Write-Host 'install-test: git archive failed'; exit 1 }
    $img = 'nextdaad-kit-linux'
    $prep = 'true'
    & docker image inspect $img *> $null
    if ($LASTEXITCODE -ne 0) {
        $img = 'ubuntu:24.04'
        $prep = 'apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates wget zip unzip git >/dev/null && wget -qO /tmp/ms.deb https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb && dpkg -i /tmp/ms.deb >/dev/null && apt-get update -qq && apt-get install -y -qq --no-install-recommends powershell >/dev/null'
    }
    # Same commands and assertions as release-kit.yml's zip step, Linux kit only.
    Write-Lf (Join-Path $cut 'zipcut.sh') (@"
set -euo pipefail
$prep
mkdir /k && tar -xf /w/kitsrc.tar -C /k
cd /k && git init -q && git add -f authoring-kit scripts
pwsh -NoProfile -File scripts/kit-files.ps1 -Check
cd authoring-kit
pwsh -NoProfile -File ../scripts/kit-files.ps1 -Platform linux | zip -q -@ /k/kit.zip
cd /k
x=`$(unzip -Z kit.zip build.sh clean.sh externs.sh run.sh vidtune.sh lib/ndrc tools/gfx2next/gfx2next | grep -c -- '-rwxr-xr-x' || true); [ "`$x" = 7 ]
n=`$(unzip -l kit.zip | grep -v ' CONFIG\.BAT`$' | grep -cE '\.(BAT|exe|dll)`$' || true); [ "`$n" = 0 ]
echo "zip: `$(unzip -l kit.zip | tail -n 1)"
cp kit.zip /w/kit.zip
"@)
    $code = Invoke-Docker @('run', '--rm', '-v', "$($cut):/w", '--entrypoint', 'bash', $img, '/w/zipcut.sh') (Join-Path $work 'zipcut.log')
    if ($code -ne 0) { Write-Host 'install-test: zip cut or its assertions FAILED'; exit 1 }
    Move-Item -LiteralPath (Join-Path $cut 'kit.zip') -Destination $dryZip -Force
    Remove-Item -LiteralPath $cut -Recurse -Force
    Write-Host "install-test: $dryZip (seven 0755 entries, no .BAT but CONFIG.BAT, no .exe/.dll)"
}

if (-not $Zip) { $Zip = $dryZip }
if ($Zip -match '^https?://') {
    $dl = Join-Path $work ([IO.Path]::GetFileName(([Uri]$Zip).AbsolutePath))
    Write-Host "install-test: downloading $Zip"
    Invoke-WebRequest -Uri $Zip -OutFile $dl
    $Zip = $dl
}
if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { Write-Host "install-test: no zip at $Zip (use -Zip, or -BuildZip for a dry run)"; exit 2 }

$passes = @('1', '2', '3', '4')
if ($Base -eq 'ubuntu:22.04') { $passes = @('1', '3') }
elseif ($Base -eq 'ubuntu:24.04') { $passes = @('2', '4') }
elseif ($Pass -ne 'all') { $passes = @($Pass) }

# Arkos: a pinned copy, never written under tools\.
$arkName = "ArkosTracker-linux64-$($pins['ARKOS_VER']).zip"
$ark = ''
foreach ($c in (Join-Path $root "tools/linux/$arkName"), (Join-Path $root "tests/out/docker-context/context/$arkName"), (Join-Path $root "tests/out/tool-cache/$arkName")) {
    if (Test-Path -LiteralPath $c) { $ark = $c; break }
}
if (-not $ark) {
    $ark = Join-Path $root "tests/out/tool-cache/$arkName"
    New-Item -ItemType Directory -Force (Split-Path $ark) | Out-Null
    Invoke-WebRequest -Uri $pins['ARKOS_LINUX_URL'] -OutFile $ark
}
if ((Sha $ark) -ne $pins['ARKOS_LINUX_SHA256']) { Write-Host "install-test: $ark does not match ARKOS_LINUX_SHA256"; exit 1 }

# Mounted read-only at /in: the zip and inputs only, never an unzipped kit
# (a bind mount keeps no file times; the kit is unzipped inside the container).
$in = Join-Path $work 'in'
if (Test-Path -LiteralPath $in) { Remove-Item -LiteralPath $in -Recurse -Force }
New-Item -ItemType Directory -Force $in | Out-Null
Copy-Item -LiteralPath $Zip -Destination (Join-Path $in 'kit.zip')
Copy-Item -LiteralPath $ark -Destination (Join-Path $in 'arkos.zip')
if (@($passes | Where-Object { '1', '2', '4' -contains $_ }).Count) {
    $mkv = Join-Path $work '003.mkv'
    if (-not (Test-Path -LiteralPath $mkv)) {
        $frames = Join-Path $work 'frames'
        New-Item -ItemType Directory -Force $frames | Out-Null
        $ff = Join-KitPath @($root, 'authoring-kit', 'tools', 'ffmpeg', 'bin', "ffmpeg$ExeSuffix")
        & $Python -c 'import sys; sys.path.insert(0, sys.argv[1]); import mkfixture; mkfixture.write_mkv(sys.argv[2], sys.argv[3], sys.argv[4])' $PSScriptRoot $mkv $ff $frames
        if ($LASTEXITCODE -ne 0) { Write-Host 'install-test: write_mkv failed'; exit 1 }
    }
    Copy-Item -LiteralPath $mkv -Destination (Join-Path $in '003.mkv')
}

# Page order: prerequisites, pwsh, unzip -d + cd, Arkos, [ffmpeg, venv], build.
$head = @'
exec 2>&1
set -e
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
echo "== $PRETTY_NAME, $(ldd --version | head -n 1)"
set -x
# A bare image has empty package lists; the page's commands run as root, so no sudo.
apt-get update -qq
apt install -y unzip wget ca-certificates >/dev/null
# Page: PowerShell 7.4 or newer from the Microsoft repo for this release.
wget -qO /tmp/ms.deb "https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb"
dpkg -i /tmp/ms.deb >/dev/null
apt-get update -qq
apt-get install -y -qq --no-install-recommends powershell >/dev/null
pwsh --version
'@
$kit = @'
cd /root
cp /in/kit.zip .
unzip -q kit.zip -d NextDAAD-AuthoringKit
cd NextDAAD-AuthoringKit
# Page: the Arkos zip extracted into tools/.
unzip -q /in/arkos.zip -d tools
test -x tools/ArkosTracker3/tools/SongToAky
'@
$py = @'
# Page: ffmpeg, then the venv recipe verbatim and in order, inside the kit folder.
apt install -y ffmpeg >/dev/null
apt install -y python3 python3-venv >/dev/null
python3 -m venv ~/nextdaad-venv
~/nextdaad-venv/bin/pip install -r lib/requirements.txt >/dev/null
'@
$activate = @'
# Page: the optional activate line.
. ~/nextdaad-venv/bin/activate
'@
# Not activated and the system python3 lacks numpy: a video build proves
# Find-Python reached ~/nextdaad-venv on its own.
$noActivate = @'
[ -z "${VIRTUAL_ENV:-}" ]
if python3 -c 'import numpy' 2>/dev/null; then echo "== the system python3 has numpy"; exit 1; fi
cp /in/003.mkv VIDEO/003.mkv
'@
$modesKept = @'
# unzip kept the execute bits, so the page's chmod line is skipped.
test -x build.sh && test -x lib/ndrc && test -x tools/gfx2next/gfx2next
'@
$build = @'
set +e
./build.sh
code=$?
set -e
echo "== ./build.sh exit $code"
[ "$code" = 0 ]
set +x
for f in $CHECK; do
    [ -f "RELEASE/$f" ] || { echo "== MISSING RELEASE/$f"; exit 1; }
    echo "== found RELEASE/$f"
done
set -x
'@
$ok = 'echo INSTALL-TEST-OK'
# Pass 4: the page's tuning-window packages and Qt libraries, still no
# activation, no FFMPEGDIR. The launcher must leave vidtune running; then
# vt4.py drives Encode Full and Accept offscreen.
$pass4Vidtune = @'
~/nextdaad-venv/bin/pip install -r lib/requirements-vidtune.txt >/dev/null
apt install -y libgl1 libegl1 libxkbcommon0 libfontconfig1 libdbus-1-3 libglib2.0-0 >/dev/null
if grep -qE 'FFMPEGDIR=[^[:space:]]' CONFIG.BAT; then echo "== CONFIG.BAT sets FFMPEGDIR"; exit 1; fi
rm -f VIDEO/003.vid VIDEO/003.vid.args
set +e
QT_QPA_PLATFORM=offscreen ./vidtune.sh
vc=$?
set -e
echo "== ./vidtune.sh exit $vc"
[ "$vc" = 0 ]
sleep 8
set +x
pids=''
for p in /proc/[0-9]*; do
    c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)
    case "$c" in *"-m vidtune"*) echo "== running: ${p#/proc/} $c"; pids="$pids ${p#/proc/}" ;; esac
done
[ -n "$pids" ] || { echo "== no -m vidtune process after ./vidtune.sh"; exit 1; }
kill $pids
set -x
QT_QPA_PLATFORM=offscreen ~/nextdaad-venv/bin/python3 /in/vt4.py
[ -f VIDEO/003.vid ]
'@
$vt4 = @'
# Pass 4: vidtune on the unzipped kit, offscreen. ffmpeg must come from PATH
# and videnc must run under vidtune's own Python; Encode Full then Accept.
import sys, time
from pathlib import Path
kit = Path.cwd()
sys.path.insert(0, str(kit / "lib"))
from PySide6.QtCore import QTimer
from PySide6.QtWidgets import QApplication
app = QApplication(sys.argv)
from vidtune.mainwindow import MainWindow
w = MainWindow(kit)
vid = kit / "VIDEO" / "003.vid"
fails = []
print("== ffmpeg", w.ffmpeg)
print("== encoder", w.encoder_argv)
if str(w.ffmpeg) != "/usr/bin/ffmpeg":
    fails.append("ffmpeg is not /usr/bin/ffmpeg")
if not w.encoder_argv or w.encoder_argv[0] != sys.executable:
    fails.append("videnc does not run under vidtune's own Python")
t0 = time.time()
def start():
    w.select_clip("003")
    w.on_encode_full()
    if w._job is None:
        fails.append("Encode Full did not start")
        finish()
    else:
        QTimer.singleShot(2000, poll)
def poll():
    if w._job is None:
        print("== encode finished:", w.statusBar().currentMessage())
        if w.accept_button.isEnabled():
            w.on_accept()
        else:
            fails.append("Accept not enabled after Encode Full")
        finish()
    elif time.time() - t0 > 1200:
        fails.append("Encode Full timed out")
        finish()
    else:
        QTimer.singleShot(2000, poll)
def finish():
    print("== VIDEO/003.vid", vid.stat().st_size if vid.is_file() else "missing", "after", int(time.time() - t0), "s")
    if not vid.is_file():
        fails.append("VIDEO/003.vid missing after Accept")
    for f in fails:
        print("== FAIL", f)
    w.close()   # closeEvent waits for preview decode threads
    app.exit(1 if fails else 0)
QTimer.singleShot(0, start)
sys.exit(app.exec())
'@
$pass2Extra = @'
cp /in/003.mkv VIDEO/003.mkv
mv INTRO.TXT.sample INTRO.TXT
'@
# ./build.sh must fail in the shell; sh build.sh must reach build.ps1's
# Test-Executable message; its chmod line, run verbatim, must fix the kit.
$pass3Extra = @'
chmod -x build.sh lib/ndrc tools/gfx2next/gfx2next
set +x +e
out1=$(./build.sh 2>&1); c1=$?
out2=$(sh build.sh 2>&1); c2=$?
set -e
echo "== ./build.sh exit $c1:"; printf '%s\n' "$out1"
echo "== sh build.sh exit $c2:"; printf '%s\n' "$out2"
[ "$c1" != 0 ] || { echo "== ./build.sh did not fail"; exit 1; }
case "$out1" in *"Permission denied"*) ;; *) echo "== no Permission denied line"; exit 1 ;; esac
[ "$c2" != 0 ] || { echo "== sh build.sh did not fail"; exit 1; }
printf '%s\n' "$out2" | grep -qF 'is not executable - run: chmod +x build.sh run.sh clean.sh externs.sh vidtune.sh lib/ndrc tools/gfx2next/gfx2next' || { echo "== no build.ps1 chmod message"; exit 1; }
fix=$(printf '%s\n' "$out2" | sed -n 's/.* is not executable - run: \(chmod +x .*\)$/\1/p' | head -n 1)
echo "== applying: $fix"
sh -c "$fix"
set -x
'@
$def = @{
    '1' = @{ Img = 'ubuntu:22.04'; Check = 'nextdaad.nex GAME.DDB 001.NX2 GAME.AKY 001.VID 003.VID'; Body = ($head, $kit, $py, $modesKept, $noActivate, $build, $ok)
        Proves = 'ubuntu:22.04 (oldest Ubuntu at the glibc 2.34 floor): page venv on Python 3.10, not activated, STARTER plus VIDEO/003.mkv' }
    '2' = @{ Img = 'ubuntu:24.04'; Check = 'nextdaad.nex GAME.DDB 003.VID STARTER.NEX INTRO/INTRO.DAT'; Body = ($head, $kit, $py, $activate, $modesKept, $pass2Extra, $build, $ok)
        Proves = 'ubuntu:24.04: page venv recipe (activated) + ffmpeg, VIDEO/003.mkv encoded and INTRO.TXT compiled' }
    '3' = @{ Img = 'ubuntu:22.04'; Check = 'nextdaad.nex GAME.DDB 001.NX2 GAME.AKY 001.VID'; Body = ($head, $kit, $pass3Extra, $build, $ok)
        Proves = 'ubuntu:22.04 with execute bits dropped: shell refuses ./build.sh, sh build.sh prints the chmod line, that line fixes the kit' }
    '4' = @{ Img = 'ubuntu:24.04'; Check = 'nextdaad.nex GAME.DDB 003.VID'; Body = ($head, $kit, $py, $modesKept, $noActivate, $build, $pass4Vidtune, $ok)
        Proves = 'ubuntu:24.04: apt ffmpeg, no FFMPEGDIR, venv not activated; build encodes 003, vidtune.sh starts, Encode Full + Accept write VIDEO/003.vid' }
}
Write-Lf (Join-Path $in 'vt4.py') $vt4
$results = @()
foreach ($p in $passes) {
    $d = $def[$p]
    Write-Lf (Join-Path $in "pass$p.sh") ((@("CHECK='$($d.Check)'") + $d.Body) -join "`n")
    Write-Host "install-test: pass $p on $($d.Img) ..."
    $log = Join-Path $work "pass$p.log"
    $code = Invoke-Docker @('run', '--rm', '-v', "$($in):/in:ro", $d.Img, 'bash', "/in/pass$p.sh") $log
    $ok = ($code -eq 0) -and ([IO.File]::ReadAllText($log).Contains('INSTALL-TEST-OK'))
    $verdict = 'FAIL'
    if ($ok) { $verdict = 'PASS' }
    $results += "install-test: pass $p $verdict - $($d.Proves)"
}
$results | ForEach-Object { Write-Host $_ }
if (@($results | Where-Object { $_ -match ' FAIL - ' }).Count) { exit 1 }
exit 0
