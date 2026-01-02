#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

CFL_CODE_DIR="${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}"
if [ -f "$HOME/cfl_watch/lib/path.sh" ]; then
  . "$HOME/cfl_watch/lib/path.sh"
  CFL_CODE_DIR="$(expand_tilde_path "$CFL_CODE_DIR")"
else
  CFL_CODE_DIR="${CFL_CODE_DIR/#\~/$HOME}"
fi

ADB_TCP_PORT="${ADB_TCP_PORT:-37099}" bash "$CFL_CODE_DIR/runner.sh" "$@"
