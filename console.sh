#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

CFL_CODE_DIR="${CFL_CODE_DIR:-~/cfl_watch}"
ADB_TCP_PORT="${ADB_TCP_PORT:-37099}" bash "$CFL_CODE_DIR/runner.sh" "$@"
