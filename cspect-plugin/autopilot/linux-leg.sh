#!/bin/bash
# Runs on the VM for run-autopilot.ps1 -Leg Linux. Writes only inside the run folder.
#   linux-leg.sh reset <run>            empty <run> (only if this script marked it)
#   linux-leg.sh run <run> <secs> <part>...   private CSpect copy, one bounded launch per part
#   linux-leg.sh kill <run>             kill CSpect started from <run>
set -u
MARK=.cspect-autopilot-stage
SRC="$HOME/nextdaad/tools/CSpect"
cmd=${1:-}; RUN=${2:-}
case "$RUN" in
    /*/*) ;;
    *) echo "refusing: run folder must be absolute: '$RUN'" >&2; exit 2 ;;
esac

# Matches the exe path, so only CSpect launched from this run folder is killed.
kill_run() {
    local pids
    pids=$(pgrep -f -- "$RUN/cspect/CSpect.exe")
    [ -n "$pids" ] || return 0
    kill $pids 2>/dev/null; sleep 2
    pids=$(pgrep -f -- "$RUN/cspect/CSpect.exe")
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    echo "killed leftover CSpect: $pids"
}

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
    [ -f "$RUN/$MARK" ] || { echo "refusing: $RUN has no $MARK" >&2; exit 2; }
    trap kill_run EXIT
    # Private copy without *.mmc and *.sd; the original is only read.
    mkdir -p "$RUN/cspect"
    (cd "$SRC" && tar cf - --exclude='*.mmc' --exclude='*.sd' .) | (cd "$RUN/cspect" && tar xf -) || { echo "CSpect copy failed" >&2; exit 3; }
    cp "$RUN/NextDAADDebug.dll" "$RUN/cspect/"
    uid=$(id -u)
    # The Xwayland auth file name changes per login.
    auth=$(ls /run/user/$uid/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
    [ -n "$auth" ] || { echo "no Xwayland auth file under /run/user/$uid" >&2; exit 3; }
    export DISPLAY=:0 XAUTHORITY="$auth" XDG_RUNTIME_DIR=/run/user/$uid
    LEG="$RUN/sd"
    i=0
    for p in "$@"; do
        i=$((i + 1))
        pd="$RUN/parts/$i-${p%.txt}"
        mkdir -p "$pd"
        rm -f "$LEG/autopilot-result.txt"; rm -rf "$LEG/dumps"
        t0=$(date +%s%N)
        (cd "$LEG" && NEXTDAAD_DEBUG="$LEG" NEXTDAAD_DEBUG_AUTOPILOT="$RUN/scripts/$p" \
            timeout -k 5 "$SECS" mono "$RUN/cspect/CSpect.exe" -w2 -zxnext -esc -sound "-mmc=$LEG/" "$LEG/nextdaad.nex" \
            > "$pd/stdout.txt" 2> "$pd/stdout.txt.err")
        rc=$?
        ms=$(( ($(date +%s%N) - t0) / 1000000 ))
        kill_run
        echo "exit=$rc ms=$ms" > "$pd/status.txt"
        echo "part $i $p: exit $rc after $ms ms"
        [ -f "$LEG/autopilot-result.txt" ] && mv "$LEG/autopilot-result.txt" "$pd/"
        [ -d "$LEG/dumps" ] && mv "$LEG/dumps" "$pd/"
        [ -f "$LEG/debugger.log" ] && cp "$LEG/debugger.log" "$pd/"
    done
    exit 0
    ;;
*)
    echo "usage: linux-leg.sh reset|run|kill <run> ..." >&2; exit 2 ;;
esac
