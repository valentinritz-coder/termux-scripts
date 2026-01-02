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
  "SNAP_ON=0 DELAY_LAUNCH=1.0 DELAY_TAP=0.25 DELAY_TYPE=0.45 DELAY_PICK=0.35 DELAY_SEARCH=1.0 bash $BASE/scenario_trip_lux_arlon.sh"
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
