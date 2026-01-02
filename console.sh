#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

ADB_TCP_PORT="${ADB_TCP_PORT:-37099}" bash /sdcard/cfl_watch/runner.sh "$@"
