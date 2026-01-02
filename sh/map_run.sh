cat > /sdcard/cfl_watch/map_run.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="/sdcard/cfl_watch"
HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-37099}"
SER="${ANDROID_SERIAL:-$HOST:$PORT}"
export ANDROID_SERIAL="$SER"

mkdir -p "$BASE"/{logs,map,tmp}

LOG="$BASE/logs/map_$(date +%Y-%m-%d_%H-%M-%S).log"

cleanup() {
  ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

{
  echo "=== START $(date) ==="
  echo "SER=$SER PORT=$PORT"

  ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" start

  # launch CFL (best effort)
  adb -s "$SER" shell monkey -p de.hafas.android.cfl -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 2

  bash -x "$BASE/map.sh" "$@"

  echo "=== END $(date) ==="
} >"$LOG" 2>&1

echo "LOG=$LOG"
tail -n 120 "$LOG"
SH

chmod +x /sdcard/cfl_watch/map_run.sh
sed -i 's/\r$//' /sdcard/cfl_watch/map_run.sh 2>/dev/null || true
