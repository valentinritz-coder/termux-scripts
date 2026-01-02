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

. "$BASE/snap.sh"

inject() { adb -s "$SER" shell "$@"; }
sleep_s() { sleep "${1:-$DELAY}"; }
tap() { inject input tap "$1" "$2" >/dev/null 2>&1 || true; }
key() { inject input keyevent "$1" >/dev/null 2>&1 || true; }

type_text() {
  local t="$1"
  t="${t//\'/}"
  t="${t// /%s}"
  inject input text "$t" >/dev/null 2>&1 || true
}

# --- Scenario start ---
snap_init "trip_${START_TEXT}_to_${TARGET_TEXT}"

echo "[*] Launch CFL"
inject monkey -p de.hafas.android.cfl -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 2
snap "00_first_screen"

# NOTE: tes coordonnées sont peut-être fausses. Si rien ne se passe, il faudra les recalibrer.
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

# --- Success heuristic ---
# Ici tu adaptes la condition "scenario fini".
# Exemple: si l'UI dump contient "Results" / "Résultats" / "Itinéraires"
if grep -qEi "Results|Résultats|Itinéraires|Trajet" "$SNAP_DIR/"*"_07_after_search.xml" 2>/dev/null; then
  echo "[+] Scenario success (results detected)"
  exit 0
fi

echo "[!] Scenario may have failed (no results keyword)"
exit 1
SH

chmod +x /sdcard/cfl_watch/scenario_trip.sh
sed -i 's/\r$//' /sdcard/cfl_watch/scenario_trip.sh 2>/dev/null || true
