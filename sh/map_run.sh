#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

CFL_CODE_DIR="${CFL_CODE_DIR:-${CFL_BASE_DIR:-~/cfl_watch}}"
CFL_ARTIFACT_DIR="${CFL_ARTIFACT_DIR:-/sdcard/cfl_watch}"
CFL_LOG_DIR="${CFL_LOG_DIR:-$CFL_ARTIFACT_DIR/logs}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-37099}"
SER="${ANDROID_SERIAL:-$HOST:$PORT}"
export ANDROID_SERIAL="$SER"

LOG_DIR="${CFL_LOG_DIR:-$CFL_ARTIFACT_DIR/logs}"
MAP_DIR="${CFL_ARTIFACT_DIR}/map"
mkdir -p "$LOG_DIR" "$MAP_DIR" "$CFL_CODE_DIR/tmp"

LOG="$LOG_DIR/map_$(date +%Y-%m-%d_%H-%M-%S).log"

cleanup() {
  ADB_TCP_PORT="$PORT" bash "$CFL_CODE_DIR/lib/adb_local.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

{
  echo "=== START $(date) ==="
  echo "SER=$SER PORT=$PORT"

  ADB_TCP_PORT="$PORT" bash "$CFL_CODE_DIR/lib/adb_local.sh" start

  # launch CFL (best effort)
  adb -s "$SER" shell monkey -p de.hafas.android.cfl -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 2

  bash -x "$SCRIPT_DIR/map.sh" --out "$MAP_DIR" "$@"

  echo "=== END $(date) ==="
} >"$LOG" 2>&1

echo "LOG=$LOG"
tail -n 120 "$LOG"
