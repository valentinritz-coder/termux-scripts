#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

CFL_CODE_DIR="${CFL_CODE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CFL_CODE_DIR="$(expand_tilde_path "$CFL_CODE_DIR")"
CFL_BASE_DIR="${CFL_BASE_DIR:-$CFL_CODE_DIR}"

if [ -f "$CFL_CODE_DIR/env.sh" ]; then
  . "$CFL_CODE_DIR/env.sh"
fi
if [ -f "$CFL_CODE_DIR/env.local.sh" ]; then
  . "$CFL_CODE_DIR/env.local.sh"
fi

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}")"
CFL_BASE_DIR="${CFL_BASE_DIR:-$CFL_CODE_DIR}"

. "$CFL_CODE_DIR/lib/common.sh"

warn(){ printf '[!] %s\n' "$*" >&2; }
log(){ printf '[*] %s\n' "$*"; }

log "Doctor report (non-blocking)"
log "CFL_CODE_DIR=$CFL_CODE_DIR"
log "CFL_ARTIFACT_DIR=$CFL_ARTIFACT_DIR"
log "CFL_TMP_DIR=$CFL_TMP_DIR"
log "ANDROID_SERIAL=${ANDROID_SERIAL:-}"
log "ADB_HOST=${ADB_HOST:-}"
log "ADB_TCP_PORT=${ADB_TCP_PORT:-}"

if [ ! -f "$CFL_CODE_DIR/env.sh" ]; then
  warn "env.sh missing at $CFL_CODE_DIR/env.sh (defaults still apply)."
fi

if [ -z "${ANDROID_SERIAL:-}" ] && { [ -z "${ADB_HOST:-}" ] || [ -z "${ADB_TCP_PORT:-}" ]; }; then
  warn "ADB_HOST/ADB_TCP_PORT not set; default serial is ${CFL_DEFAULT_HOST}:${CFL_DEFAULT_PORT}."
fi

if [[ "$CFL_TMP_DIR" == /data/data/com.termux/* ]]; then
  warn "CFL_TMP_DIR is under /data/data/com.termux (uiautomator cannot access)."
fi

if [ ! -d "/sdcard" ]; then
  warn "/sdcard is not accessible. Run: termux-setup-storage."
fi

log "Doctor done."
exit 0
