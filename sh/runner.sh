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

cleanup() {
  # best effort: stop adb local
  ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

die(){ echo "[!] $*" >&2; exit 1; }

# --- sanity checks ---
command -v adb >/dev/null 2>&1 || die "adb introuvable (pkg install android-tools)"
[ -f "$BASE/adb_local.sh" ] || die "adb_local.sh introuvable: $BASE/adb_local.sh"
[ -f "$SCENARIO_SCRIPT" ] || die "Scenario introuvable: $SCENARIO_SCRIPT"

echo "[*] Start ADB local on $SER"
ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" start

echo "[*] Device:"
adb -s "$SER" devices -l || true

echo "[*] Scenario script: $SCENARIO_SCRIPT"
if command -v sha1sum >/dev/null 2>&1; then
  echo "[*] scenario sha1: $(sha1sum "$SCENARIO_SCRIPT" | awk '{print $1}')"
fi

# --- Scenario list (tu peux en ajouter autant que tu veux) ---
# Format: "START|TARGET|SNAP_ON|DELAY_LAUNCH|DELAY_TAP|DELAY_TYPE|DELAY_PICK|DELAY_SEARCH"
SCENARIOS=(
  "LUXEMBOURG|ARLON|1|1.0|0.25|0.45|0.35|1.0"
  "ESCH-SUR-ALZETTE|LUXEMBOURG|1|1.0|0.25|0.45|0.35|1.0"
)

run_one() {
  local start="$1"
  local target="$2"
  local snap_on="$3"
  local d_launch="$4"
  local d_tap="$5"
  local d_type="$6"
  local d_pick="$7"
  local d_search="$8"

  echo
  echo "=== RUN: START='$start' TARGET='$target' SNAP_ON=$snap_on ==="

  echo "[*] Force-stop CFL (clean state)"
  adb -s "$SER" shell am force-stop "$PKG" >/dev/null 2>&1 || true
  sleep 0.8

  echo "[*] Launch CFL (cold start)"
  adb -s "$SER" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 1.2

  set +e
  START_TEXT="$start" \
  TARGET_TEXT="$target" \
  SNAP_ON="$snap_on" \
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
  sleep 1

  return "$rc"
}

fail_count=0
idx=0
for row in "${SCENARIOS[@]}"; do
  idx=$((idx+1))
  IFS='|' read -r START TARGET SNAP_ON DLAUNCH DTAP DTYPE DPICK DSEARCH <<<"$row"

  # valeurs par défaut au cas où
  SNAP_ON="${SNAP_ON:-0}"
  DLAUNCH="${DLAUNCH:-1.0}"
  DTAP="${DTAP:-0.25}"
  DTYPE="${DTYPE:-0.45}"
  DPICK="${DPICK:-0.35}"
  DSEARCH="${DSEARCH:-1.0}"

  if ! run_one "$START" "$TARGET" "$SNAP_ON" "$DLAUNCH" "$DTAP" "$DTYPE" "$DPICK" "$DSEARCH"; then
    echo "[!] Scenario #$idx FAILED"
    fail_count=$((fail_count+1))
  fi
done

echo
echo "[*] Done. fail_count=$fail_count LOG=$LOG"
exit 0
