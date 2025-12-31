cat > /sdcard/cfl_watch/map_run.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="/sdcard/cfl_watch"
mkdir -p "$BASE"/{logs,map,tmp}
export ANDROID_SERIAL="${ANDROID_SERIAL:-127.0.0.1:5555}"
SER="$ANDROID_SERIAL"

LOG="$BASE/logs/map_$(date +%Y-%m-%d_%H-%M-%S).log"
{
  echo "=== START $(date) ==="
  echo "SER=$SER"

  bash "$BASE/adb_local.sh" start

  # launch CFL (best effort)
  adb -s "$SER" shell monkey -p de.hafas.android.cfl -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 2

  bash -x "$BASE/map.sh" "$@"

  bash "$BASE/adb_local.sh" stop
  echo "=== END $(date) ==="
} >"$LOG" 2>&1

echo "LOG=$LOG"
tail -n 80 "$LOG"
SH

chmod +x /sdcard/cfl_watch/map_run.sh
sed -i 's/\r$//' /sdcard/cfl_watch/map_run.sh 2>/dev/null || true
