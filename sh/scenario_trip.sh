cat > /sdcard/cfl_watch/scenario_trip.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="/sdcard/cfl_watch"
mkdir -p "$BASE"/{logs,tmp}

HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-37099}"
SER="${ANDROID_SERIAL:-$HOST:$PORT}"

START_TEXT="${1:-Luxembourg}"
TARGET_TEXT="${2:-Arlon}"
DELAY="${DELAY:-1.2}"

TS="$(date +%Y-%m-%d_%H-%M-%S)"
LOG="$BASE/logs/scenario_$TS.log"
TMP="$BASE/tmp/scenario_$TS"
mkdir -p "$TMP"

exec > >(tee -a "$LOG") 2>&1

inject() { adb -s "$SER" shell "$@"; }
sleep_s() { sleep "${1:-$DELAY}"; }

tap() { echo "[*] tap $1 $2"; inject input tap "$1" "$2" || true; }
key() { echo "[*] keyevent $1"; inject input keyevent "$1" || true; }

type_text() {
  local t="$1"
  # input text n'aime pas certains caractères, on garde simple
  t="${t//\'/}"
  t="${t// /%s}"
  echo "[*] type_text: $t"
  inject input text "$t" || true
}

dump_ui() {
  local name="$1"
  echo "[*] dump_ui $name"
  inject uiautomator dump --compressed "$TMP/$name.xml" >/dev/null 2>&1 || true
}

shot() {
  local name="$1"
  echo "[*] screenshot $name"
  inject screencap -p "$TMP/$name.png" >/dev/null 2>&1 || true
}

echo "=== scenario_trip START $TS ==="
echo "[*] SER=$SER PORT=$PORT"
adb -s "$SER" get-state || { echo "[!] adb not ready"; exit 1; }

echo "[*] Current focus:"
inject dumpsys window windows 2>/dev/null | grep -E "mCurrentFocus|mFocusedApp" || true

echo "[*] Display:"
inject wm size 2>/dev/null || true
inject wm density 2>/dev/null || true
inject dumpsys input 2>/dev/null | grep -i "SurfaceOrientation" || true

# Pre-capture
dump_ui "00_before"
shot "00_before"

# Petit "probe" tap pour vérifier que input passe (en bas à gauche)
tap 80 2200
sleep_s 0.3
shot "01_after_probe"

# Assure-toi que CFL est au premier plan
echo "[*] Force launch CFL"
inject monkey -p de.hafas.android.cfl -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 2
dump_ui "02_after_launch"
shot "02_after_launch"

echo "[*] Focus after launch:"
inject dumpsys window windows 2>/dev/null | grep -E "mCurrentFocus|mFocusedApp" || true

# --- Essai avec tes coordonnées actuelles ---
echo "[*] Try DEST field (coords: 518 561)"
tap 518 561
sleep_s 0.6
type_text "$TARGET_TEXT"
sleep_s 0.3
key 66
sleep_s 1.2
dump_ui "03_after_dest"
shot "03_after_dest"

echo "[*] Try START field (coords: 518 407)"
tap 518 407
sleep_s 0.6
type_text "$START_TEXT"
sleep_s 0.3
key 66
sleep_s 1.2
dump_ui "04_after_start"
shot "04_after_start"

echo "[*] Try SEARCH button (coords: 970 561)"
tap 970 561
sleep_s 2.0
dump_ui "05_after_search"
shot "05_after_search"

echo "[*] Heuristic check for text in UI dump:"
if grep -qiE "Luxembourg|Arlon" "$TMP/04_after_start.xml" 2>/dev/null; then
  echo "[+] Found typed text in UI XML"
else
  echo "[!] Typed text NOT found in UI XML (coords/focus likely wrong)"
fi

echo "[*] Artifacts in: $TMP"
echo "[*] Log: $LOG"
echo "=== scenario_trip END ==="
SH

chmod +x /sdcard/cfl_watch/scenario_trip.sh
sed -i 's/\r$//' /sdcard/cfl_watch/scenario_trip.sh 2>/dev/null || true
