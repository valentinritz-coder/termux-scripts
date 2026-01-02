#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="/sdcard/cfl_watch"
HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-37099}"
SER="${ANDROID_SERIAL:-$HOST:$PORT}"
export ANDROID_SERIAL="$SER"

START_TEXT="Luxembourg"
TARGET_TEXT="Arlon (Belgium)"
DELAY="${DELAY:-1.0}"

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

dump_ui() {
  local dump_path="$BASE/tmp/live_dump.xml"
  mkdir -p "$BASE/tmp"
  inject uiautomator dump --compressed "$dump_path" >/dev/null 2>&1 || true
  echo "$dump_path"
}

node_center() {
  local dump="$1"
  shift
  python - "$dump" "$@" <<'PY' 2>/dev/null
import sys
import xml.etree.ElementTree as ET

dump = sys.argv[1]
pairs = [arg.split("=", 1) for arg in sys.argv[2:]]
criteria = []
for key, value in pairs:
    attr = {
        "resource-id": "resource-id",
        "text": "text",
        "content-desc": "content-desc",
        "class": "class",
    }.get(key, key)
    criteria.append((attr, value))

try:
    tree = ET.parse(dump)
except Exception:
    sys.exit(0)

def parse_bounds(b):
    try:
        left_top, right_bottom = b.strip("[]").split("][")
        x1, y1 = map(int, left_top.split(","))
        x2, y2 = map(int, right_bottom.split(","))
        return (x1 + x2) // 2, (y1 + y2) // 2
    except Exception:
        return None

for node in tree.iter():
    ok = True
    for attr, expected in criteria:
        actual = node.get(attr, "")
        if expected.lower() not in actual.lower():
            ok = False
            break
    if ok:
        bounds = node.get("bounds")
        if bounds:
            center = parse_bounds(bounds)
            if center:
                print(f"{center[0]} {center[1]}")
                sys.exit(0)
sys.exit(0)
PY
}

tap_by_selector() {
  local label="$1"
  shift
  local dump
  dump="$(dump_ui)"
  local coords
  coords="$(node_center "$dump" "$@")"
  if [[ -z "${coords// }" ]]; then
    echo "[!] Unable to find selector for $label with criteria: $*"
    return 1
  fi

  local x y
  read -r x y <<<"$coords"
  echo "[*] Tap $label at $x,$y"
  tap "$x" "$y"
  return 0
}

# --- Scenario start ---
snap_init "trip_Luxembourg_to_Arlon"

echo "[*] Launch CFL"
inject monkey -p de.hafas.android.cfl -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 2
snap "00_launch"

echo "[*] Open destination field"
snap "01_before_tap_destination"
tap_by_selector "destination field" "resource-id=de.hafas.android.cfl:id/input_target" || tap_by_selector "destination field (fallback)" "content-desc=Select destination"
sleep_s 0.6
snap "02_after_tap_destination"

echo "[*] Type destination: $TARGET_TEXT"
snap "03_before_type_destination"
type_text "$TARGET_TEXT"
sleep_s 0.6
snap "04_after_type_destination"

echo "[*] Choose destination suggestion"
snap "05_before_pick_destination"
tap_by_selector "destination suggestion" "text=$TARGET_TEXT" || tap_by_selector "destination suggestion (first result)" "resource-id=de.hafas.android.cfl:id/text_location_name" "text=Arlon"
sleep_s 0.8
snap "06_after_pick_destination"

echo "[*] Open start field"
snap "07_before_tap_start"
tap_by_selector "start field" "content-desc=Select start" || tap_by_selector "start field (history)" "resource-id=de.hafas.android.cfl:id/input_start"
sleep_s 0.6
snap "08_after_tap_start"

echo "[*] Type start: $START_TEXT"
snap "09_before_type_start"
type_text "$START_TEXT"
sleep_s 0.6
snap "10_after_type_start"

echo "[*] Choose start suggestion"
snap "11_before_pick_start"
tap_by_selector "start suggestion" "text=$START_TEXT" || tap_by_selector "start suggestion (first result)" "resource-id=de.hafas.android.cfl:id/text_location_name" "text=Luxembourg"
sleep_s 0.8
snap "12_after_pick_start"

echo "[*] Launch search"
snap "13_before_search"
tap_by_selector "search button" "resource-id=de.hafas.android.cfl:id/button_search_default" || tap_by_selector "search button (home)" "resource-id=de.hafas.android.cfl:id/button_search"
sleep_s 2.0
snap "14_after_search"

echo "[*] Evaluate result heuristics"
latest_xml="$(ls -1t "$SNAP_DIR"/*_after_search.xml 2>/dev/null | head -n1 || true)"
if [[ -z "$latest_xml" ]]; then
  echo "[!] No after_search snapshot found; treating as failure"
  exit 1
fi

if inject grep -qiE "Results|Résultats|Itinéraires" "$latest_xml"; then
  echo "[+] Scenario success (keyword detected in results)"
  exit 0
fi

if inject grep -qiE "trip_recycler_view|trip_result|tripItem" "$latest_xml"; then
  echo "[+] Scenario success (trip list detected)"
  exit 0
fi

echo "[!] Scenario may have failed (no results markers found)"
exit 1
