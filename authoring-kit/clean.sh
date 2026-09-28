#!/bin/sh
# Launcher only. The build is lib/clean.ps1; keep this file trivial.
cd "$(dirname "$0")" || exit 1
command -v pwsh >/dev/null 2>&1 || { echo "ERROR: pwsh (PowerShell 7) not found - see docs/getting-started.html, Linux setup"; exit 1; }
exec pwsh -NoProfile -File lib/clean.ps1 "$@"
