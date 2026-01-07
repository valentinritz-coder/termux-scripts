#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Parameterized CFL trip scenario
# Env: START_TEXT, TARGET_TEXT, SNAP_MODE, DELAY_*, CFL_DRY_RUN
#
# Notes:
# - IDs sont gérés en suffixe ":id/..." pour ne pas dépendre du package.
# - dump_ui écrit le chemin du fichier sur stdout (pour d="$(dump_ui)"),
#   et loggue uniquement sur stderr.

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

: "${CFL_TMP_DIR:=$HOME/.cache/cfl_watch}"            # local Termux (lecture rapide)
: "${CFL_REMOTE_TMP_DIR:=/data/local/tmp/cfl_watch}"  # côté adb shell (écriture rapide)
: "${CFL_DUMP_TIMING:=1}"                             # 1 = log timings, 0 = silence

# IDs en suffixe (robuste)
ID_START=":id/input_start"
ID_TARGET=":id/input_target"
ID_PROGRESS=":id/progress_location_loading"
ID_RESULTS=":id/list_location_results"
ID_BTN_SEARCH=":id/button_search"
ID_BTN_SEARCH_DEFAULT=":id/button_search_default"

need python

# -------------------------
# Helpers: regex resource-id
# -------------------------

resid_regex(){
  # Build a regex that matches a resource-id in uiautomator dump.
  # If resid is ":id/foo" -> resource-id="ANY:id/foo"
  # Else assume full id and match exactly-ish.
  local resid="$1"
  if [[ "$resid" == :id/* ]]; then
    local suffix="${resid#:id/}"
    printf 'resource-id="[^"]*:id/%s"' "$suffix"
  else
    # escape dots for regex
    printf 'resource-id="%s"' "${resid//./\\.}"
  fi
}

# -------------------------
# UI dump (remote -> local)
# -------------------------

dump_ui(){
  local remote_dir="$CFL_REMOTE_TMP_DIR"
  local remote_path="$remote_dir/live_dump.xml"

  local local_dir="$CFL_TMP_DIR"
  local local_path="$local_dir/live_dump.xml"

  mkdir -p "$local_dir" >/dev/null 2>&1 || true
  inject mkdir -p "$remote_dir" >/dev/null 2>&1 || true

  local t0 t1 t2 dump_ms cat_ms total_ms
  t0=$(date +%s%N)

  # Nettoyage remote uniquement (évite stale côté device)
  inject rm -f "$remote_path" >/dev/null 2>&1 || true

  # 1) dump côté device (remote)
  inject uiautomator dump --compressed "$remote_path" >/dev/null 2>&1 || true
  t1=$(date +%s%N)

  if ! inject test -s "$remote_path" >/dev/null 2>&1; then
    warn "dump_ui: remote dump absent/vide: $remote_path"
  fi

  # 2) rapatrier en local Termux via tmp + mv (atomic-ish)
  local tmp_local="$local_path.tmp.$$"
  if inject cat "$remote_path" > "$tmp_local" 2>/dev/null && [ -s "$tmp_local" ]; then
    mv -f "$tmp_local" "$local_path"
  else
    rm -f "$tmp_local" >/dev/null 2>&1 || true
    warn "dump_ui: impossible de lire $remote_path (fallback sdcard)"

    # fallback sdcard (anti-stale + tmp + mv)
    local sd_dir="/sdcard/cfl_watch/tmp"
    local sd_path="$sd_dir/live_dump.xml"
    local sd_tmp="$sd_path.tmp.$$"

    inject mkdir -p "$sd_dir" >/dev/null 2>&1 || true
    inject rm -f "$sd_path" >/dev/null 2>&1 || true

    inject uiautomator dump --compressed "$sd_tmp" >/dev/null 2>&1 || true
    if inject test -s "$sd_tmp" >/dev/null 2>&1; then
      inject mv -f "$sd_tmp" "$sd_path" >/dev/null 2>&1 || true
      local_path="$sd_path"
    else
      inject rm -f "$sd_tmp" >/dev/null 2>&1 || true
      # on garde local_path tel quel: si tu as un ancien $local_path valide, il reste utilisable
      warn "dump_ui: fallback sdcard dump absent/vide: $sd_tmp"
    fi
  fi
  t2=$(date +%s%N)

  dump_ms=$(( (t1-t0)/1000000 ))
  cat_ms=$(( (t2-t1)/1000000 ))
  total_ms=$(( (t2-t0)/1000000 ))

  # validations (sur ce qu'on retourne)
  if [ ! -s "$local_path" ]; then
    warn "UI dump absent/vide: $local_path"
  elif ! grep -q "<hierarchy" "$local_path" 2>/dev/null; then
    warn "UI dump invalide (pas de <hierarchy): $local_path"
  fi

  if [ "${CFL_DUMP_TIMING:-1}" = "1" ]; then
    printf '[*] ui_dump: dump=%sms cat=%sms total=%sms -> %s\n' \
      "$dump_ms" "$cat_ms" "$total_ms" "$local_path" >&2
  fi

  printf '%s' "$local_path"
}

# -------------------------
# Wait helpers (dump + grep)
# -------------------------

wait_dump_grep(){
  # usage: wait_dump_grep "<regex>" [timeout_s] [interval_s]
  local regex="$1"
  local timeout_s="${2:-10}"
  local interval_s="${3:-1.0}"
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
  local resid="$1"
  local timeout_s="${2:-10}"
  local interval_s="${3:-1.0}"

  local pat
  pat="$(resid_regex "$resid")"
  wait_dump_grep "$pat" "$timeout_s" "$interval_s" >/dev/null
}

wait_resid_absent(){
  local resid="$1"
  local timeout_s="${2:-10}"
  local interval_s="${3:-1}"
  local stable_n="${4:-2}"
  local end=$(( $(date +%s) + timeout_s ))

  local pat
  pat="$(resid_regex "$resid")"

  local ok=0
  while [ "$(date +%s)" -lt "$end" ]; do
    local d; d="$(dump_ui)"
    if grep -Eq "$pat" "$d" 2>/dev/null; then
      ok=0
    else
      ok=$((ok+1))
      [ "$ok" -ge "$stable_n" ] && return 0
    fi
    sleep "$interval_s"
  done

  warn "wait_resid_absent timeout: resid=$resid"
  return 1
}

wait_results_ready(){
  # Attendre que les suggestions soient prêtes après saisie.
  # - 1 seule boucle
  # - 1 dump UI par itération
  # - interval conseillé: 1.0s (vu que dump_ui coûte déjà 2-3s...)
  #
  # Conditions de sortie:
  #   OK "fort": list présente ET loader absent
  #   OK "faible": list présente (certains écrans n'ont pas le loader)
  #
  # Usage:
  #   wait_results_ready 12 1.0 || true

  local timeout_s="${1:-12}"
  local interval_s="${2:-1.0}"

  # match "n'importe quel package:id/xxx"
  local re_list='resource-id="[^"]*:id/list_location_results"'
  local re_loader='resource-id="[^"]*:id/progress_location_loading"'

  local end=$(( $(date +%s) + timeout_s ))

  local iter=0
  local last_state=""
  while [ "$(date +%s)" -lt "$end" ]; do
    iter=$((iter+1))

    local d
    d="$(dump_ui)"

    local has_list=0 has_loader=0
    grep -Eq "$re_list" "$d" 2>/dev/null && has_list=1 || true
    grep -Eq "$re_loader" "$d" 2>/dev/null && has_loader=1 || true

    # debug compact (optionnel)
    local state="iter=$iter list=$has_list loader=$has_loader"
    if [ "${CFL_DUMP_TIMING:-1}" = "1" ] && [ "$state" != "$last_state" ]; then
      log "wait_results_ready: $state"
      last_state="$state"
    fi

    # OK fort
    if [ "$has_list" -eq 1 ] && [ "$has_loader" -eq 0 ]; then
      return 0
    fi
    # OK faible
    if [ "$has_list" -eq 1 ]; then
      return 0
    fi

    sleep "$interval_s"
  done

  warn "wait_results_ready timeout ($timeout_s s) last=$last_state"
  return 1
}

# -------------------------
# Selector/tap helpers
# -------------------------

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
        # contains (case-insensitive)
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
LIST_SUFFIX = ":id/list_location_results"

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
    rid = n.get("resource-id","")
    if rid.endswith(LIST_SUFFIX):
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

# -------------------------
# Run setup
# -------------------------

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
log "CFL_REMOTE_TMP_DIR=${CFL_REMOTE_TMP_DIR:-<unset>}"

# -------------------------
# Scenario
# -------------------------

# App should already be launched by runner, but keep a safety net:
maybe cfl_launch

# Wait for start input
wait_resid_present "$ID_START" 12 1.5 || sleep_s 2
snap "00_launch" "$SNAP_MODE"

# START
snap "01_before_tap_start" "$SNAP_MODE"
dump_cache="$(dump_ui)"

# Prefer stable id first; content-desc often changes with locale/accessibility
tap_by_selector "start field (id)" "$dump_cache" "resource-id=$ID_START" \
  || tap_by_selector "start field (content-desc)" "$dump_cache" "content-desc=Select start"

snap "02_after_tap_start" "$SNAP_MODE"

log "Type start: $START_TEXT"
sleep_s 0.10
maybe type_text "$START_TEXT"

wait_results_ready 12 1.5 || true
snap "03_after_type_start" "$SNAP_MODE"

dump_cache="$(dump_ui)"
tap_by_selector "start suggestion (desc contains)" "$dump_cache" "content-desc=$START_TEXT" \
  || tap_by_selector "start suggestion (text contains)" "$dump_cache" "text=$START_TEXT" \
  || tap_first_result "start suggestion (first)" "$dump_cache"

# After selecting start, destination field should be reachable
wait_resid_present "$ID_TARGET" 12 1.5 || wait_dump_grep 'content-desc="Select destination"' 12 0.25 >/dev/null || sleep_s 1
snap "04_after_pick_start" "$SNAP_MODE"

# DESTINATION
snap "05_before_tap_destination" "$SNAP_MODE"
dump_cache="$(dump_ui)"

tap_by_selector "destination field (id)" "$dump_cache" "resource-id=$ID_TARGET" \
  || tap_by_selector "destination field (content-desc)" "$dump_cache" "content-desc=Select destination"

snap "06_after_tap_destination" "$SNAP_MODE"

log "Type destination: $TARGET_TEXT"
sleep_s 0.10
maybe type_text "$TARGET_TEXT"

wait_results_ready 12 1.5 || true
snap "07_after_type_destination" "$SNAP_MODE"

dump_cache="$(dump_ui)"
tap_by_selector "destination suggestion (desc contains)" "$dump_cache" "content-desc=$TARGET_TEXT" \
  || tap_by_selector "destination suggestion (text contains)" "$dump_cache" "text=$TARGET_TEXT" \
  || tap_first_result "destination suggestion (first)" "$dump_cache"

# Wait for search button (any known form)
wait_dump_grep "$(resid_regex "$ID_BTN_SEARCH_DEFAULT")|$(resid_regex "$ID_BTN_SEARCH")|text=\"Rechercher\"|text=\"Itinéraires\"" 12 1.5 >/dev/null || sleep_s 1
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
