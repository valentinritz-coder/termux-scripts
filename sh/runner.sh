#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="/sdcard/cfl_watch"
HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-37099}"
SER="${ANDROID_SERIAL:-$HOST:$PORT}"
export ANDROID_SERIAL="$SER"

PKG="de.hafas.android.cfl"
SCENARIO_SCRIPT="$BASE/scenario_trip_lux_arlon.sh"

mkdir -p "$BASE/logs"

TS="$(date +%Y-%m-%d_%H-%M-%S)"
LOG="$BASE/logs/runner_$TS.log"
exec > >(tee -a "$LOG") 2>&1

die(){ echo "[!] $*" >&2; exit 1; }

cleanup() {
  # best effort: stop adb local
  if [ -f "$BASE/adb_local.sh" ]; then
    ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" stop >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- sanity checks ---
command -v adb >/dev/null 2>&1 || die "adb introuvable (pkg install android-tools)"
[ -f "$BASE/adb_local.sh" ] || die "adb_local.sh introuvable: $BASE/adb_local.sh"
[ -f "$SCENARIO_SCRIPT" ] || die "Scenario introuvable: $SCENARIO_SCRIPT"

chmod +x "$BASE/adb_local.sh" "$SCENARIO_SCRIPT" >/dev/null 2>&1 || true

echo "[*] Start ADB local on $SER"
ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" start

echo "[*] Device:"
adb -s "$SER" devices -l || true

echo "[*] Scenario script: $SCENARIO_SCRIPT"
if command -v sha1sum >/dev/null 2>&1; then
  echo "[*] scenario sha1: $(sha1sum "$SCENARIO_SCRIPT" | awk '{print $1}')"
fi

# --- Scenario list ---
# Format: START|TARGET|SNAP_MODE|DELAY_LAUNCH|DELAY_TAP|DELAY_TYPE|DELAY_PICK|DELAY_SEARCH
# SNAP_MODE: 0=off, 1=png only, 2=xml only, 3=png+xml
SCENARIOS=(
  "LUXEMBOURG|ARLON|1|1.0|0.20|0.30|0.25|0.80"
  "ESCH-SUR-ALZETTE|LUXEMBOURG|1|1.0|0.20|0.30|0.25|0.80"
)

run_one() {
  local start="$1" target="$2" snap_mode="$3"
  local d_launch="$4" d_tap="$5" d_type="$6" d_pick="$7" d_search="$8"

  echo
  echo "=== RUN: START='$start' TARGET='$target' SNAP_MODE=$snap_mode ==="

  echo "[*] Force-stop CFL (clean state)"
  adb -s "$SER" shell am force-stop "$PKG" >/dev/null 2>&1 || true
  sleep 0.6

  # IMPORTANT: le scénario gère le launch. Le runner ne lance pas l’app.
  set +e
  START_TEXT="$start" \
  TARGET_TEXT="$target" \
  SNAP_MODE="$snap_mode" \
  DELAY_LAUNCH="$d_launch" \
  DELAY_TAP="$d_tap" \
  DELAY_TYPE="$d_type" \
  DELAY_PICK="$d_pick" \
  DELAY_SEARCH="$d_search" \
  bash "$SCENARIO_SCRIPT"
  local rc=$?
  set -e

  echo "=== RC=$rc ==="

  echo "[*] Force-stop CFL (after run)"
  adb -s "$SER" shell am force-stop "$PKG" >/dev/null 2>&1 || true
  sleep 0.8

  return "$rc"
}

fail_count=0
idx=0

for row in "${SCENARIOS[@]}"; do
  idx=$((idx+1))
  IFS='|' read -r START TARGET SNAP_MODE DLAUNCH DTAP DTYPE DPICK DSEARCH <<<"$row"

  SNAP_MODE="${SNAP_MODE:-1}"
  DLAUNCH="${DLAUNCH:-1.0}"
  DTAP="${DTAP:-0.20}"
  DTYPE="${DTYPE:-0.30}"
  DPICK="${DPICK:-0.25}"
  DSEARCH="${DSEARCH:-0.80}"

  if ! run_one "$START" "$TARGET" "$SNAP_MODE" "$DLAUNCH" "$DTAP" "$DTYPE" "$DPICK" "$DSEARCH"; then
    echo "[!] Scenario #$idx FAILED"
    fail_count=$((fail_count+1))
  fi
done

echo
echo "[*] Done. fail_count=$fail_count LOG=$LOG"
exit 0
