cat > /sdcard/cfl_watch/scenario_trip.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="/sdcard/cfl_watch"
HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-37099}"
SER="${ANDROID_SERIAL:-$HOST:$PORT}"
export ANDROID_SERIAL="$SER"

START_TEXT="${1:-Luxembourg}"
TARGET_TEXT="${2:-Arlon}"
DELAY="${DELAY:-1.2}"

mkdir -p "$BASE/logs" "$BASE/tmp" "$BASE/runs"

TS="$(date +%Y-%m-%d_%H-%M-%S)"
LOG="$BASE/logs/scenario_trip_$TS.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== scenario_trip START $TS ==="
echo "[*] SER=$SER PORT=$PORT"
echo "[*] args: START=$START_TEXT TARGET=$TARGET_TEXT"
echo "[*] LOG=$LOG"

# charge snap lib
. "$BASE/snap.sh"
declare -F snap_init >/dev/null 2>&1 || { echo "[!] snap_init introuvable"; exit 2; }
declare -F snap      >/dev/null 2>&1 || { echo "[!] snap introuvable"; exit 2; }

inject() { adb -s "$SER" shell "$@"; }
sleep_s() { sleep "${1:-$DELAY}"; }
tap() { echo "[*] tap $1 $2"; inject input tap "$1" "$2" >/dev/null 2>&1 || true; }
key() { echo "[*] key $1"; inject input keyevent "$1" >/dev/null 2>&1 || true; }

type_text() {
  local t="$1"
  t="${t//\'/}"
  t="${t// /%s}"
  echo "[*] type: $t"
  inject input text "$t" >/dev/null 2>&1 || true
}

snap_init "trip_${START_TEXT}_to_${TARGET_TEXT}"

echo "[*] Launch CFL (monkey)"
inject monkey -p de.hafas.android.cfl -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 2

echo "[*] Focus after launch:"
inject dumpsys window windows 2>/dev/null | grep -E "mCurrentFocus|mFocusedApp" || true

snap "00_first_screen"

echo "[*] Destination"
tap 518 561
sleep_s 0.6
snap "01_after_tap_dest"
type_text "$TARGET_TEXT"
sleep_s 0.3
snap "02_after_type_dest"
key 66
sleep_s 1.0
snap "03_after_enter_dest"

echo "[*] Start"
tap 518 407
sleep_s 0.6
snap "04_after_tap_start"
type_text "$START_TEXT"
sleep_s 0.3
snap "05_after_type_start"
key 66
sleep_s 1.0
snap "06_after_enter_start"

echo "[*] Search"
tap 970 561
sleep_s 2.0
snap "07_after_search"

# sanity: on veut AU MOINS des fichiers
count_files="$(ls -1 "$SNAP_DIR" 2>/dev/null | wc -l | tr -d ' ')"
echo "[*] SNAP_DIR files: $count_files"
ls -1 "$SNAP_DIR" 2>/dev/null | tail -n 20 || true

# heuristique de succès
if grep -qEi "Results|Résultats|Itinéraires|Trajet" "$SNAP_DIR/"*"_07_after_search.xml" 2>/dev/null; then
  echo "[+] Scenario success (keyword detected)"
  echo "=== scenario_trip END (OK) ==="
  exit 0
fi

echo "[!] Scenario failed (no keyword detected)"
echo "=== scenario_trip END (FAIL) ==="
exit 1
SH

chmod +x /sdcard/cfl_watch/scenario_trip.sh
sed -i 's/\r$//' /sdcard/cfl_watch/scenario_trip.sh 2>/dev/null || true
