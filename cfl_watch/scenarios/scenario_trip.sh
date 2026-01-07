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

# Default delays (kept, but we try to avoid sleeping blindly)
DELAY_LAUNCH="${DELAY_LAUNCH:-2.0}"
DELAY_SEARCH="${DELAY_SEARCH:-0.40}"
DELAY_TAP="${DELAY_TAP:-0.15}"
DELAY_TYPE="${DELAY_TYPE:-0.15}"
DELAY_PICK="${DELAY_PICK:-0.15}"

: "${CFL_TMP_DIR:=$HOME/.cache/cfl_watch}"          # local Termux (lecture rapide)
: "${CFL_REMOTE_TMP_DIR:=/data/local/tmp/cfl_watch}" # côté adb shell (écriture rapide)
: "${CFL_DUMP_TIMING:=1}"                            # 1 = log timings, 0 = silence

# Hafas/CFL ids (keep consistent everywhere)
PKG="de.hafas.android.cfl"
ID_START="$PKG:id/input_start"
ID_TARGET="$PKG:id/input_target"
ID_PROGRESS="$PKG:id/progress_location_loading"
ID_RESULTS="$PKG:id/list_location_results"
ID_BTN_SEARCH="$PKG:id/button_search"
ID_BTN_SEARCH_DEFAULT="$PKG:id/button_search_default"

need python

dump_ui(){
  local remote_dir="$CFL_REMOTE_TMP_DIR"
  local remote_path="$remote_dir/live_dump.xml"

  local local_dir="$CFL_TMP_DIR"
  local local_path="$local_dir/live_dump.xml"

  mkdir -p "$local_dir" >/dev/null 2>&1 || true
  inject mkdir -p "$remote_dir" >/dev/null 2>&1 || true

  local t0 t1 t2 dump_ms cat_ms total_ms
  t0=$(date +%s%N)

  # 1) dump rapide côté shell (remote)
  inject uiautomator dump --compressed "$remote_path" >/dev/null 2>&1 || true
  t1=$(date +%s%N)

  # 2) rapatrier le XML en local Termux (lisible par grep/python)
  if ! inject cat "$remote_path" > "$local_path" 2>/dev/null; then
    warn "dump_ui: impossible de lire $remote_path (fallback sdcard)"
    # fallback: dump direct sur sdcard si tu veux sauver la mise
    local_path="/sdcard/cfl_watch/tmp/live_dump.xml"
    inject mkdir -p "/sdcard/cfl_watch/tmp" >/dev/null 2>&1 || true
    inject uiautomator dump --compressed "$local_path" >/dev/null 2>&1 || true
  fi
  t2=$(date +%s%N)

  dump_ms=$(( (t1-t0)/1000000 ))
  cat_ms=$(( (t2-t1)/1000000 ))
  total_ms=$(( (t2-t0)/1000000 ))

  # validations (sur le fichier local Termux ou sdcard fallback)
  if [ ! -s "$local_path" ]; then
    warn "UI dump absent/vide: $local_path"
  elif ! grep -q "<hierarchy" "$local_path" 2>/dev/null; then
    warn "UI dump invalide (pas de <hierarchy): $local_path"
  fi

  if [ "${CFL_DUMP_TIMING:-1}" = "1" ]; then
    log "ui_dump: dump=${dump_ms}ms cat=${cat_ms}ms total=${total_ms}ms -> $local_path"
  fi

  printf '%s' "$local_path"
}

# ---- Wait helpers based on dump file (single source of truth) ----

wait_dump_grep(){
  # Wait until grep matches in freshly dumped UI
  # usage: wait_dump_grep "<regex>" [timeout_s] [interval_s]
  local regex="$1"
  local timeout_s="${2:-10}"
  local interval_s="${3:-0.25}"
  local end=$(( $(date +%s) + timeout_s ))

  while [ "$(date +%s)" -lt "$end" ]; do
    local d
    d="$(dump_ui)"
    if grep -Eq "$regex" "$d" 2>/dev/null; then
      printf '%s' "$d"
      return 0
    fi
    sleep "$interval_s"
  done

  warn "wait_dump_grep timeout: regex=$regex"
  return 1
}

wait_resid_present(){
  # Wait until resource-id is present in dump
  local resid="$1"
  local timeout_s="${2:-10}"
  local interval_s="${3:-0.25}"
  wait_dump_grep "resource-id=\"${resid//./\\.}\"" "$timeout_s" "$interval_s" >/dev/null
}

wait_resid_absent(){
  # Wait until resource-id disappears (stable for N dumps)
  local resid="$1"
  local timeout_s="${2:-10}"
  local interval_s="${3:-0.25}"
  local stable_n="${4:-2}"
  local end=$(( $(date +%s) + timeout_s ))

  local ok=0
  while [ "$(date +%s)" -lt "$end" ]; do
    local d
    d="$(dump_ui)"
    if grep -Fq "resource-id=\"$resid\"" "$d" 2>/dev/null; then
      ok=0
    else
      ok=$((ok+1))
      if [ "$ok" -ge "$stable_n" ]; then
        return 0
      fi
    fi
    sleep "$interval_s"
  done

  warn "wait_resid_absent timeout: resid=$resid"
  return 1
}

wait_focused_resid(){
  # Wait until a node with resource-id has focused="true" (more reliable than keyboard visibility)
  local resid="$1"
  local timeout_s="${2:-8}"
  local interval_s="${3:-0.25}"
  local end=$(( $(date +%s) + timeout_s ))

  while [ "$(date +%s)" -lt "$end" ]; do
    local d
    d="$(dump_ui)"
    # Usually each node is a single line in uiautomator dump, so this is fine.
    if grep -F "resource-id=\"$resid\"" "$d" 2>/dev/null | grep -Fq 'focused="true"'; then
      return 0
    fi
    sleep "$interval_s"
  done

  warn "wait_focused_resid timeout: resid=$resid"
  return 1
}

wait_results_ready(){
  # Wait until results are "ready enough" after typing:
  # - Either list appears (ID_RESULTS)
  # - Prefer: list present AND loader absent (ID_PROGRESS)
  local timeout_s="${1:-10}"
  local interval_s="${2:-0.25}"
  local end=$(( $(date +%s) + timeout_s ))

  while [ "$(date +%s)" -lt "$end" ]; do
    local d
    d="$(dump_ui)"

    local has_list=0 has_loader=0
    grep -Fq "resource-id=\"$ID_RESULTS\"" "$d" 2>/dev/null && has_list=1 || true
    grep -Fq "resource-id=\"$ID_PROGRESS\"" "$d" 2>/dev/null && has_loader=1 || true

    # Best case
    if [ "$has_list" -eq 1 ] && [ "$has_loader" -eq 0 ]; then
      return 0
    fi

    # Acceptable (some UIs don't show loader)
    if [ "$has_list" -eq 1 ]; then
      return 0
    fi

    sleep "$interval_s"
  done

  warn "wait_results_ready timeout (list/loader not in expected state)"
  return 1
}

# ---- Selector/tap helpers (python-based center) ----

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

# ---- Run setup ----

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

# ---- Scenario ----

# App should already be launched by runner, but keep a safety net:
maybe cfl_launch

# Wait for start input OR at least the app UI to be there
wait_resid_present "$ID_START" 12 0.20 || sleep_s 2
snap "00_launch" "$SNAP_MODE"

# START
snap "01_before_tap_start" "$SNAP_MODE"
dump_cache="$(dump_ui)"

# Prefer stable id first; content-desc often changes with locale/accessibility
tap_by_selector "start field (id)" "$dump_cache" "resource-id=$ID_START" \
  || tap_by_selector "start field (content-desc)" "$dump_cache" "content-desc=Select start"

snap "02_after_tap_start" "$SNAP_MODE"

log "Type start: $START_TEXT"
# Wait for focus instead of keyboard
wait_focused_resid "$ID_START" 6 0.25 || true
maybe type_text "$START_TEXT"

# Wait for suggestions/results to be ready
wait_results_ready 10 0.25 || true
snap "03_after_type_start" "$SNAP_MODE"

dump_cache="$(dump_ui)"
tap_by_selector "start suggestion (exact desc)" "$dump_cache" "content-desc=$START_TEXT" \
  || tap_by_selector "start suggestion (exact text)" "$dump_cache" "text=$START_TEXT" \
  || tap_first_result "start suggestion (first)" "$dump_cache"

# After selecting start, destination field should be reachable
# Wait for target input OR a known fallback selector
wait_dump_grep "resource-id=\"${ID_TARGET//./\\.}\"|content-desc=\"Select destination\"" 12 0.25 >/dev/null || sleep_s 1
snap "04_after_pick_start" "$SNAP_MODE"

# DESTINATION
snap "05_before_tap_destination" "$SNAP_MODE"
dump_cache="$(dump_ui)"

tap_by_selector "destination field (id)" "$dump_cache" "resource-id=$ID_TARGET" \
  || tap_by_selector "destination field (content-desc)" "$dump_cache" "content-desc=Select destination"

snap "06_after_tap_destination" "$SNAP_MODE"

log "Type destination: $TARGET_TEXT"
wait_focused_resid "$ID_TARGET" 6 0.25 || true
maybe type_text "$TARGET_TEXT"

wait_results_ready 10 0.25 || true
snap "07_after_type_destination" "$SNAP_MODE"

dump_cache="$(dump_ui)"
tap_by_selector "destination suggestion (exact desc)" "$dump_cache" "content-desc=$TARGET_TEXT" \
  || tap_by_selector "destination suggestion (exact text)" "$dump_cache" "text=$TARGET_TEXT" \
  || tap_first_result "destination suggestion (first)" "$dump_cache"

# Wait for search button in any known form
wait_dump_grep "resource-id=\"${ID_BTN_SEARCH_DEFAULT//./\\.}\"|resource-id=\"${ID_BTN_SEARCH//./\\.}\"|text=\"Rechercher\"|text=\"Itinéraires\"" 12 0.25 >/dev/null || sleep_s 1
snap "08_after_pick_destination" "$SNAP_MODE"

# SEARCH
snap "09_before_search" "$SNAP_MODE"
dump_cache="$(dump_ui)"

if ! (
  tap_by_selector "search button (id default)" "$dump_cache" "resource-id=$ID_BTN_SEARCH_DEFAULT" \
  || tap_by_selector "search button (id home)"    "$dump_cache" "resource-id=$ID_BTN_SEARCH" \
  || tap_by_selector "search button (text FR)"    "$dump_cache" "text=Rechercher" \
  || tap_by_selector "search button (text trips)" "$dump_cache" "text=Itinéraires"
); then
  warn "Search button not found -> ENTER fallback"
  maybe key 66 || true
fi

# Force full artifacts here even if SNAP_MODE=1/2, because it's the important step
snap "10_after_search" 3

# Quick heuristic on last xml (if any)
latest_xml="$(ls -1t "$SNAP_DIR"/*.xml 2>/dev/null | head -n1 || true)"
if [[ -n "${latest_xml:-}" ]] && grep -qiE 'Results|Résultats|Itinéraire|Itinéraires|Trajet' "$latest_xml"; then
  log "Scenario success (keyword detected)"
  exit 0
fi

warn "Scenario ended without strong marker (not necessarily a failure)"
exit 0
