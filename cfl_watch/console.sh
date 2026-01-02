#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

CFL_BASE_DIR="${CFL_BASE_DIR:-/sdcard/cfl_watch}"

ADB_TCP_PORT="${ADB_TCP_PORT:-37099}" bash "$CFL_BASE_DIR/runner.sh" "$@"
