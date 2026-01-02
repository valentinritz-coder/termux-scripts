#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="/sdcard/cfl_watch"
HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-37099}"
SER="${ANDROID_SERIAL:-$HOST:$PORT}"
export ANDROID_SERIAL="$SER"

START_TEXT="LUXEMBOURG"
TARGET_TEXT="ARLON"
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
import sys, re
import xml.etree.ElementTree as ET

dump = sys.argv[1]
pairs = [arg.split("=", 1) for arg in sys.argv[2:]]

keymap = {
  "resource-id": "resource-id",
  "text": "text",
  "content-desc": "content-desc",
  "class": "class",
  "clickable": "clickable",
}
criteria = [(keymap.get(k, k), v) for k, v in pairs]

def parse_bounds(b):
  m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b or "")
  if not m: return None
  x1,y1,x2,y2 = map(int, m.groups())
  if x2 <= x1 or y2 <= y1: return None
  return (x1+x2)//2, (y1+y2)//2

try:
  root = ET.parse(dump).getroot()
except Exception:
  sys.exit(0)

parent = {c: p for p in root.iter() for c in p}

def matches(node):
  for attr, expected in criteria:
    actual = node.get(attr, "") or ""
    if expected.lower() not in actual.lower():
      return False
  return True

for node in root.iter("node"):
  if not matches(node):
    continue

  cur = node
  while cur is not None and cur.get("clickable", "") != "true":
    cur = parent.get(cur)

  target = cur if cur is not None else node
  c = parse_bounds(target.get("bounds"))
  if c:
    print(f"{c[0]} {c[1]}")
    sys.exit(0)

sys.exit(0)
PY
}

first_result_center() {
  local dump="$1"
  python - "$dump" <<'PY' 2>/dev/null
import re, sys
import xml.etree.ElementTree as ET

dump = sys.argv[1]
LIST_ID = "de.hafas.android.cfl:id/list_location_results"

def parse_bounds(b):
  m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b or "")
  if not m:
    return None
  x1,y1,x2,y2 = map(int, m.groups())
  if x2 <= x1 or y2 <= y1:
    return None
  return x1,y1,x2,y2

def center(bb):
  x1,y1,x2,y2 = bb
  return (x1+x2)//2, (y1+y2)//2

try:
  root = ET.parse(dump).getroot()
except Exception:
  sys.exit(0)

# Trouver le RecyclerView des résultats
list_node = None
for n in root.iter("node"):
  if n.get("resource-id") == LIST_ID:
    list_node = n
    break
if list_node is None:
  sys.exit(0)

list_bounds = parse_bounds(list_node.get("bounds"))
if not list_bounds:
  sys.exit(0)

# Parcourir ses enfants et prendre le premier item clickable (souvent ViewGroup)
for child in list_node.iter("node"):
  if child is list_node:
    continue
  if child.get("clickable") == "true" and child.get("enabled") != "false":
    bb = parse_bounds(child.get("bounds"))
    if not bb:
      continue
    # Optionnel: ignorer petits boutons (ex: étoile favorite)
    w = bb[2]-bb[0]; h = bb[3]-bb[1]
    if w*h < 20000:
      continue
    x,y = center(bb)
    print(f"{x} {y}")
    sys.exit(0)

sys.exit(0)
PY
}

tap_first_result() {
  local label="${1:-first result}"
  local dump
  dump="$(dump_ui)"
  local coords
  coords="$(first_result_center "$dump")"
  if [[ -z "${coords// }" ]]; then
    echo "[!] Unable to find $label (no first result coords)"
    return 1
  fi
  local x y
  read -r x y <<<"$coords"
  echo "[*] Tap $label at $x,$y"
  tap "$x" "$y"
  return 0
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

finish() {
  rc=$?
  trap - EXIT

  if [ -n "${SNAP_DIR:-}" ] && [ -d "${SNAP_DIR:-}" ] && [ "$rc" -ne 0 ]; then
    echo "[*] Run FAILED (rc=$rc) -> génération viewers..."
    bash /sdcard/cfl_watch/post_run_viewers.sh "$SNAP_DIR" || true
    echo "[*] Viewers OK: $SNAP_DIR/viewers/index.html"
  fi
}
trap finish EXIT

# ----------------------------------
# ----------------------------------
# START OF SCENARIO-------------------
# ----------------------------------
# ----------------------------------

echo "[*] Launch CFL"
inject monkey -p de.hafas.android.cfl -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 2.0
snap "00_launch"

# ----------------------------------

echo "[*] Open start field"
snap "01_before_tap_start"
tap_by_selector "start field" "content-desc=Select start" \
|| tap_by_selector "start field (history)" "resource-id=de.hafas.android.cfl:id/input_start"
sleep_s 0.8
snap "02_after_tap_start"

echo "[*] Type start: $START_TEXT"
snap "03_before_type_start"
type_text "$START_TEXT"
sleep_s 0.8
snap "04_after_type_start"

echo "[*] Choose start suggestion"
snap "05_before_pick_start"
tap_by_selector "start suggestion" "content-desc=$START_TEXT" \
|| tap_by_selector "start suggestion (text)" "text=$START_TEXT" \
|| tap_first_result "start suggestion (first result)"
sleep_s 0.8
snap "06_after_pick_start"

# ----------------------------------

echo "[*] Open destination field"
snap "07_before_tap_destination"
tap_by_selector "destination field" "resource-id=de.hafas.android.cfl:id/input_target" \
|| tap_by_selector "destination field (fallback)" "content-desc=Select destination"
sleep_s 0.8
snap "08_after_tap_destination"

echo "[*] Type destination: $TARGET_TEXT"
snap "09_before_type_destination"
type_text "$TARGET_TEXT"
sleep_s 0.8
snap "10_after_type_destination"

echo "[*] Choose destination suggestion"
snap "11_before_pick_destination"
tap_by_selector "destination suggestion" "content-desc=$TARGET_TEXT" \
|| tap_by_selector "destination suggestion (text)" "text=$TARGET_TEXT" \
|| tap_first_result "destination suggestion (first result)"
sleep_s 0.8
snap "12_after_pick_destination"

# ----------------------------------

echo "[*] Launch search"
snap "13_before_search"
if ! (
  tap_by_selector "search button (id default)" "resource-id=de.hafas.android.cfl:id/button_search_default" \
  || tap_by_selector "search button (id home)"    "resource-id=de.hafas.android.cfl:id/button_search" \
  || tap_by_selector "search button (rid contains search)" "resource-id=search" \
  || tap_by_selector "search button (text FR)" "text=Rechercher" \
  || tap_by_selector "search button (text trips)" "text=Itinéraires"
); then
  echo "[!] Search button not found -> fallback ENTER"
  key 66 || true
fi
sleep_s 2.0
snap "14_after_search"

# ----------------------------------
# ----------------------------------
# END OF SCENARIO-------------------
# ----------------------------------
# ----------------------------------

echo "[*] Evaluate result heuristics"
latest_xml="$(ls -1t "$SNAP_DIR"/*_after_search.xml 2>/dev/null | head -n1 || true)"
if [[ -z "$latest_xml" ]]; then
  echo "[!] No after_search snapshot found; treating as failure"
  exit 1
fi

if grep -qiE 'Results|Résultats|Itinéraire|Itinéraires' "$latest_xml"; then
  echo "[+] Scenario success (keyword detected in results)"
  exit 0
fi

if grep -qiE 'trip_recycler_view|trip_result|tripItem' "$latest_xml"; then
  echo "[+] Scenario success (trip list detected)"
  exit 0
fi

echo "[!] Scenario may have failed (no results markers found)"
exit 1
