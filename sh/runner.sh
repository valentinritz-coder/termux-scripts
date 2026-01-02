cat > /sdcard/cfl_watch/runner.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="/sdcard/cfl_watch"
HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-37099}"
SER="${ANDROID_SERIAL:-$HOST:$PORT}"
export ANDROID_SERIAL="$SER"

mkdir -p "$BASE"/logs

TS="$(date +%Y-%m-%d_%H-%M-%S)"
LOG="$BASE/logs/runner_$TS.log"
exec > >(tee -a "$LOG") 2>&1

cleanup() {
  ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[*] Start ADB local on $SER"
ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" start

# Liste de scénarios
SCENARIOS=(
  "bash -x $BASE/scenario_trip.sh Luxembourg Arlon"
)

for cmd in "${SCENARIOS[@]}"; do
  echo
  echo "=== RUN: $cmd ==="

  echo "[*] scenario_trip.sh path: $BASE/scenario_trip.sh"
  if command -v sha1sum >/dev/null 2>&1; then
    echo "[*] scenario_trip.sh sha1: $(sha1sum "$BASE/scenario_trip.sh" | awk '{print $1}')"
  fi
  echo "[*] scenario_trip.sh head:"
  sed -n '1,80p' "$BASE/scenario_trip.sh" || true
  echo "----"

  set +e
  eval "$cmd"
  rc=$?
  set -e

  echo "=== RC=$rc ==="

  echo "[*] Force-stop CFL"
  adb -s "$SER" shell am force-stop de.hafas.android.cfl >/dev/null 2>&1 || true
  sleep 1
done

echo "[*] Done. LOG=$LOG"
SH

chmod +x /sdcard/cfl_watch/runner.sh
sed -i 's/\r$//' /sdcard/cfl_watch/runner.sh 2>/dev/null || true
