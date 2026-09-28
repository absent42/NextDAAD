#!/bin/sh
# Launcher only. /src or -src = Python source mode, as VIDTUNE.BAT.
cd "$(dirname "$0")" || exit 1
command -v pwsh >/dev/null 2>&1 || { echo "ERROR: pwsh (PowerShell 7) not found - see docs/getting-started.html, Linux setup"; exit 1; }
case "$1" in /src|-src|-Src) shift; set -- -Src "$@" ;; esac
exec pwsh -NoProfile -File lib/vidtune.ps1 "$@"
