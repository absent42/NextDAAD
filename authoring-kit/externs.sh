#!/bin/sh
# Launcher only. Module paths resolve against the caller's directory.
caller="$(pwd)"
cd "$(dirname "$0")" || exit 1
command -v pwsh >/dev/null 2>&1 || { echo "ERROR: pwsh (PowerShell 7) not found - see docs/getting-started.html, Linux setup"; exit 1; }
exec pwsh -NoProfile -File lib/externs.ps1 -BaseDir "$caller" "$@"
