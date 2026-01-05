#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Parameterized CFL trip scenario
# Env: START_TEXT, TARGET_TEXT, SNAP_MODE, DELAY_*, CFL_DRY_RUN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}")"
CFL_BASE_DIR="$CFL_CODE_DIR"
. "$CFL_CODE_DIR/lib/common.sh"
. "$CFL_CODE_DIR/lib/snap.sh"

START_TEXT="${START_TEXT:-LUXEMBOURG}"
TARGET_TEXT="${TARGET_TEXT:-ARLON}"
SNAP_MODE="${SNAP_MODE:-1}"

DELAY_LAUNCH="${DELAY_LAUNCH:-1.0}"
DELAY_TAP="${DELAY_TAP:-0.20}"
DELAY_TYPE="${DELAY_TYPE:-0.30}"
DELAY_PICK="${DELAY_PICK:-0.25}"
DELAY_SEARCH="${DELAY_SEARCH:-0.80}"

dump_ui(){
  : "${CFL_TMP_DIR:="$CFL_BASE_DIR/tmp"}"   # fallback au cas où
  local dump_path="$CFL_TMP_DIR/live_dump.xml"

  mkdir -p "$CFL_TMP_DIR"

  # Laisse TEMPORAIREMENT les erreurs visibles (au moins en debug)
  inject uiautomator dump --compressed "$dump_path" >/dev/null 2>&1 || true

  # Sanity checks côté appareil (via inject)
  if ! inject test -s "$dump_path" >/dev/null 2>&1; then
    warn "UI dump absent/vide: $dump_path"
  elif ! inject grep -q "<hierarchy" "$dump_path" >/dev/null 2>&1; then
    warn "UI dump invalide (pas de <hierarchy): $dump_path"
  fi

  printf '%s' "$dump_path"
}


node_center(){
  local dump="$1"; shift
  python - "$dump" "$@" <<'PY' 2>/dev/null
import sys, re, xml.etree.ElementTree as ET
dump = sys.argv[1]
pairs = [a.split("=",1) for a in sys.argv[2:]]
criteria = [(k,v) for k,v in pairs]

_bounds = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")

def center(bounds):
    m = _bounds.match(bounds or "")
    if not m:
        return None
    x1,y1,x2,y2 = map(int, m.groups())
    if x2<=x1 or y2<=y1:
        return None
    return (x1+x2)//2, (y1+y2)//2

try:
    root = ET.parse(dump).getroot()
except Exception:
    sys.exit(0)

parent = {c:p for p in root.iter() for c in p}

def matches(node):
    for attr, expected in criteria:
        actual = node.get(attr,"") or ""
        if expected.lower() not in actual.lower():
            return False
    return True

for node in root.iter("node"):
    if not matches(node):
        continue
    cur = node
    while cur is not None and cur.get("clickable","") != "true":
        cur = parent.get(cur)
    target = cur if cur is not None else node
    c = center(target.get("bounds"))
    if c:
        print(f"{c[0]} {c[1]}")
        sys.exit(0)
sys.exit(0)
PY
}

first_result_center(){
  local dump="$1"
  python - "$dump" <<'PY' 2>/dev/null
import re, sys, xml.etree.ElementTree as ET
dump = sys.argv[1]
LIST_ID = "de.hafas.android.cfl:id/list_location_results"
_bounds = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")

def parse(b):
    m = _bounds.match(b or "")
    if not m:
        return None
    x1,y1,x2,y2 = map(int, m.groups())
    if x2<=x1 or y2<=y1:
        return None
    return x1,y1,x2,y2

def ctr(bb):
    x1,y1,x2,y2 = bb
    return (x1+x2)//2, (y1+y2)//2

try:
    root = ET.parse(dump).getroot()
except Exception:
    sys.exit(0)

list_node = None
for n in root.iter("node"):
    if n.get("resource-id") == LIST_ID:
        list_node = n
        break
if list_node is None:
    sys.exit(0)

for child in list_node.iter("node"):
    if child is list_node:
        continue
    if child.get("clickable") == "true" and child.get("enabled") != "false":
        bb = parse(child.get("bounds"))
        if not bb:
            continue
        w = bb[2]-bb[0]; h = bb[3]-bb[1]
        if w*h < 20000:
            continue
        x,y = ctr(bb)
        print(f"{x} {y}")
        sys.exit(0)
sys.exit(0)
PY
}

tap_by_selector(){
  local label="$1"; shift
  local dump="$1"; shift
  local coords
  coords="$(node_center "$dump" "$@")"
  if [[ -z "${coords// }" ]]; then
    warn "Selector introuvable: $label (criteria: $*)"
    return 1
  fi
  local x y
  read -r x y <<<"$coords"
  log "Tap $label at $x,$y"
  maybe tap "$x" "$y"
  return 0
}

tap_first_result(){
  local label="$1"
  local dump="$2"
  local coords
  coords="$(first_result_center "$dump")"
  if [[ -z "${coords// }" ]]; then
    warn "Pas de $label"
    return 1
  fi
  local x y
  read -r x y <<<"$coords"
  log "Tap $label at $x,$y"
  maybe tap "$x" "$y"
  return 0
}

run_name="trip_$(safe_name "$START_TEXT")_to_$(safe_name "$TARGET_TEXT")"
snap_init "$run_name"

finish(){
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    warn "Run FAILED (rc=$rc) -> viewer"
    "$CFL_CODE_DIR/lib/viewer.sh" "$SNAP_DIR" >/dev/null 2>&1 || true
    log "Viewer: $SNAP_DIR/viewers/index.html"
  fi
  exit "$rc"
}
trap finish EXIT

log "Scenario: $START_TEXT -> $TARGET_TEXT (SNAP_MODE=$SNAP_MODE)"

log "CFL_CODE_DIR=$CFL_CODE_DIR"
log "CFL_BASE_DIR=$CFL_BASE_DIR"
log "CFL_TMP_DIR=${CFL_TMP_DIR:-<unset>}"


# App should already be launched by runner, but ok to keep a launch safety net:
maybe cfl_launch
sleep_s "$DELAY_LAUNCH"
snap "00_launch" "$SNAP_MODE"

# START
snap "01_before_tap_start" "$SNAP_MODE"
dump_cache="$(dump_ui)"
tap_by_selector "start field" "$dump_cache" "content-desc=Select start" \
  || tap_by_selector "start field (history)" "$dump_cache" "resource-id=de.hafas.android.cfl:id/input_start"
sleep_s "$DELAY_TAP"
snap "02_after_tap_start" "$SNAP_MODE"

log "Type start: $START_TEXT"
maybe type_text "$START_TEXT"
sleep_s "$DELAY_TYPE"
snap "03_after_type_start" "$SNAP_MODE"

dump_cache="$(dump_ui)"
tap_by_selector "start suggestion" "$dump_cache" "content-desc=$START_TEXT" \
  || tap_by_selector "start suggestion (text)" "$dump_cache" "text=$START_TEXT" \
  || tap_first_result "start suggestion (first)" "$dump_cache"
sleep_s "$DELAY_PICK"
snap "04_after_pick_start" "$SNAP_MODE"

# DESTINATION
snap "05_before_tap_destination" "$SNAP_MODE"
dump_cache="$(dump_ui)"
tap_by_selector "destination field" "$dump_cache" "resource-id=de.hafas.android.cfl:id/input_target" \
  || tap_by_selector "destination field (fallback)" "$dump_cache" "content-desc=Select destination"
sleep_s "$DELAY_TAP"
snap "06_after_tap_destination" "$SNAP_MODE"

log "Type destination: $TARGET_TEXT"
maybe type_text "$TARGET_TEXT"
sleep_s "$DELAY_TYPE"
snap "07_after_type_destination" "$SNAP_MODE"

dump_cache="$(dump_ui)"
tap_by_selector "destination suggestion" "$dump_cache" "content-desc=$TARGET_TEXT" \
  || tap_by_selector "destination suggestion (text)" "$dump_cache" "text=$TARGET_TEXT" \
  || tap_first_result "destination suggestion (first)" "$dump_cache"
sleep_s "$DELAY_PICK"
snap "08_after_pick_destination" "$SNAP_MODE"

# SEARCH
snap "09_before_search" "$SNAP_MODE"
dump_cache="$(dump_ui)"
if ! (
  tap_by_selector "search button (id default)" "$dump_cache" "resource-id=de.hafas.android.cfl:id/button_search_default" \
  || tap_by_selector "search button (id home)"    "$dump_cache" "resource-id=de.hafas.android.cfl:id/button_search" \
  || tap_by_selector "search button (text FR)"    "$dump_cache" "text=Rechercher" \
  || tap_by_selector "search button (text trips)" "$dump_cache" "text=Itinéraires"
); then
  warn "Search button not found -> ENTER fallback"
  maybe key 66 || true
fi

sleep_s "$DELAY_SEARCH"
# Force full artifacts here even if SNAP_MODE=1/2, because it's the important step
snap "10_after_search" 3

# quick heuristic on last xml (if any)
latest_xml="$(ls -1t "$SNAP_DIR"/*.xml 2>/dev/null | head -n1 || true)"
if [[ -n "${latest_xml:-}" ]] && grep -qiE 'Results|Résultats|Itinéraire|Itinéraires|Trajet' "$latest_xml"; then
  log "Scenario success (keyword detected)"
  exit 0
fi

warn "Scenario ended without strong marker (not necessarily a failure)"
exit 0
