#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

CFL_BASE_DIR="${CFL_BASE_DIR:-/sdcard/cfl_watch}"
. "$CFL_BASE_DIR/lib/common.sh"

attach_log "self_check"
self_check
