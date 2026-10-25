#!/bin/bash
# Runs on the VM for run-autopilot.ps1 -Leg Linux. Writes only inside the run folder.
#   linux-leg.sh reset <run>            empty <run> (only if this script marked it)
#   linux-leg.sh run <run> <secs> <part>...   private CSpect copy, one bounded launch per part
#   linux-leg.sh kit <run>              leg K: CSpect copy, ./build.sh and ./debug.sh -NoLaunch in <run>/kit, facts in <run>/out
#   linux-leg.sh kitrun <run> <secs> <part> <arg>...   leg K: the Autopilot DLL swapped in, one launch from <run>/kit
#   linux-leg.sh kill <run>             kill CSpect started from <run>
set -u -o pipefail
MARK=.cspect-autopilot-stage
SRC="$HOME/nextdaad/tools/CSpect"
cmd=${1:-}; RUN=${2:-}
case "$RUN" in
    /*/*) ;;
    *) echo "refusing: run folder must be absolute: '$RUN'" >&2; exit 2 ;;
esac
# Never inside the VM's own NextDAAD tree (SRC lives there).
case "$RUN/" in
    "$HOME/nextdaad/"*) echo "refusing: run folder is under $HOME/nextdaad: '$RUN'" >&2; exit 2 ;;
esac

# The exe path as one whole argument, regex-escaped, so only CSpect from this run folder matches.
EXE_RE="(^| )$(printf '%s' "$RUN/cspect/CSpect.exe" | sed 's/[.]/[.]/g')( |$)"
kill_run() {
    local pids left
    pids=$(pgrep -f -- "$EXE_RE")
    [ -n "$pids" ] || return 0
    kill $pids 2>/dev/null; sleep 2
    left=$(pgrep -f -- "$EXE_RE")
    [ -n "$left" ] && kill -9 $left 2>/dev/null
    echo "killed leftover CSpect:" $pids
}

need_mark() { [ -f "$RUN/$MARK" ] || { echo "refusing: $RUN has no $MARK" >&2; exit 2; }; }

# Private copy without *.mmc and *.sd; the original is only read.
copy_cspect() {
    mkdir -p "$RUN/cspect"
    (cd "$SRC" && tar cf - --exclude='*.mmc' --exclude='*.sd' .) | (cd "$RUN/cspect" && tar xf -) || { echo "CSpect copy failed" >&2; exit 3; }
}

x11_env() {
    local uid auth
    uid=$(id -u)
    # The Xwayland auth file name changes per login.
    auth=$(ls /run/user/$uid/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
    [ -n "$auth" ] || { echo "no Xwayland auth file under /run/user/$uid" >&2; exit 3; }
    export DISPLAY=:0 XAUTHORITY="$auth" XDG_RUNTIME_DIR=/run/user/$uid
}

# launch_part <i> <part> <cwd> <NEXTDAAD_DEBUG folder> <CSpect argument>...; results into parts/<i>-<part>/.
launch_part() {
    local i=$1 p=$2 cwd=$3 g=$4 pd t0 rc ms
    shift 4
    pd="$RUN/parts/$i-${p%.txt}"
    mkdir -p "$pd"
    rm -f "$g/autopilot-result.txt"; rm -rf "$g/dumps"
    t0=$(date +%s%N)
    # Same debugger variables as the Windows launch; nothing inherited from the login.
    (cd "$cwd" && env -u NEXTDAAD_DEBUG_TRACE -u NEXTDAAD_DEBUG_NOWINDOW -u NEXTDAAD_DEBUG_SETTINGS \
        NEXTDAAD_DEBUG="$g" NEXTDAAD_DEBUG_AUTOPILOT="$RUN/scripts/$p" \
        timeout -k 5 "$SECS" mono "$RUN/cspect/CSpect.exe" "$@" \
        > "$pd/stdout.txt" 2> "$pd/stdout.txt.err")
    rc=$?
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    kill_run
    echo "exit=$rc ms=$ms" > "$pd/status.txt"
    echo "part $i $p: exit $rc after $ms ms"
    [ -f "$g/autopilot-result.txt" ] && mv "$g/autopilot-result.txt" "$pd/"
    [ -d "$g/dumps" ] && mv "$g/dumps" "$pd/"
    [ -f "$g/debugger.log" ] && cp "$g/debugger.log" "$pd/"
}

# RELEASE/DBGKIT files, sorted, '|'-joined.
release_tree() { (cd RELEASE/DBGKIT 2>/dev/null && find . -type f | sed 's|^\./||' | LC_ALL=C sort | paste -sd'|' -); }

case "$cmd" in
reset)
    if [ -e "$RUN" ]; then
        [ -f "$RUN/$MARK" ] || { echo "refusing: $RUN exists and has no $MARK" >&2; exit 2; }
        kill_run
        rm -rf -- "$RUN"
    fi
    mkdir -p -- "$RUN" && echo "staged by run-autopilot.ps1 -Leg Linux" > "$RUN/$MARK"
    ;;
kill)
    [ -f "$RUN/$MARK" ] || exit 0
    kill_run
    ;;
run)
    SECS=$3; shift 3
    need_mark
    trap kill_run EXIT
    copy_cspect
    cp "$RUN/NextDAADDebug.dll" "$RUN/cspect/"
    x11_env
    LEG="$RUN/sd"
    i=0
    for p in "$@"; do
        i=$((i + 1))
        # The esxDOS plugin trims one trailing separator and needs one left to enter DATA.
        launch_part "$i" "$p" "$LEG" "$LEG" -w2 -zxnext -esc -sound "-mmc=$LEG//" "$LEG/nextdaad.nex"
    done
    exit 0
    ;;
kit)
    need_mark
    copy_cspect
    OUT="$RUN/out"
    mkdir -p "$OUT"
    if [ -e "$RUN/cspect/NextDAADDebug.dll" ]; then echo present; else echo absent; fi > "$OUT/plugin-before.txt"
    cd "$RUN/kit" || exit 3
    # scp carries no modes: the chmod line build.ps1 asks an author for.
    chmod +x build.sh run.sh clean.sh externs.sh vidtune.sh debug.sh lib/ndrc tools/gfx2next/gfx2next || exit 3
    ./build.sh > "$OUT/build.txt" 2>&1; echo $? > "$OUT/build.rc"
    release_tree > "$OUT/tree-before.txt"
    ./debug.sh -NoLaunch > "$OUT/debug-nolaunch.txt" 2>&1; echo $? > "$OUT/debug.rc"
    release_tree > "$OUT/tree-after.txt"
    if [ -f "$RUN/cspect/NextDAADDebug.dll" ]; then sha256sum < "$RUN/cspect/NextDAADDebug.dll" | cut -d' ' -f1; else echo none; fi > "$OUT/plugin-sha.txt"
    cp -r DBGKIT "$OUT/"
    exit 0
    ;;
kitrun)
    SECS=$3; P=$4; shift 4
    need_mark
    trap kill_run EXIT
    cp "$RUN/NextDAADDebug.dll" "$RUN/cspect/"
    x11_env
    launch_part 1 "$P" "$RUN/kit" "$RUN/kit/DBGKIT" "$@"
    exit 0
    ;;
*)
    echo "usage: linux-leg.sh reset|run|kit|kitrun|kill <run> ..." >&2; exit 2 ;;
esac
