#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# CFL trip scenario (API version, readable)
# Env: START_TEXT, TARGET_TEXT, SNAP_MODE, WAIT_* , CFL_DRY_RUN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}")"
CFL_BASE_DIR="$CFL_CODE_DIR"

. "$CFL_CODE_DIR/lib/common.sh"
. "$CFL_CODE_DIR/lib/snap.sh"

# UI libs (new)
. "$CFL_CODE_DIR/lib/ui_core.sh"
. "$CFL_CODE_DIR/lib/ui_select.sh"
. "$CFL_CODE_DIR/lib/ui_api.sh"

START_TEXT="${START_TEXT:-LUXEMBOURG}"
TARGET_TEXT="${TARGET_TEXT:-ARLON}"
SNAP_MODE="${SNAP_MODE:-2}"   # 2 = xml only (fast), 3 = xml+png (slower)

# IDs (suffix) used by ui_wait_search_button
ID_START=":id/input_start"
ID_TARGET=":id/input_target"
ID_BTN_SEARCH=":id/button_search"
ID_BTN_SEARCH_DEFAULT=":id/button_search_default"

# waits
WAIT_POLL="${WAIT_POLL:-0.0}"
WAIT_SHORT="${WAIT_SHORT:-20}"
WAIT_LONG="${WAIT_LONG:-30}"

need python

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

# -------------------------
# -------------------------
# -------------------------
# -------------------------
# Scenario
# -------------------------
# -------------------------
# -------------------------
# -------------------------

log "Scenario: $START_TEXT -> $TARGET_TEXT (SNAP_MODE=$SNAP_MODE)"

maybe cfl_launch

# 0) Home: attendre champ start
ui_wait_resid "start field visible" "$ID_START" "$WAIT_LONG"
ui_snap "01_home" "$SNAP_MODE"

# 1) START: tap champ start
ui_tap_any "start field" \
  "resid:$ID_START" \
  "desc:Select start" \
  "desc:start" \
  "desc:origine" \
  "desc:départ" \
|| true
ui_snap_here "02_after_tap_start" "$SNAP_MODE"

# 2) START: taper + suggestions
ui_type_and_wait_results "start" "$START_TEXT"
ui_snap "03_after_type_start" "$SNAP_MODE"

# 3) START: choisir suggestion
ui_pick_suggestion "start suggestion" "$START_TEXT"
ui_refresh
ui_snap "04_after_pick_start" "$SNAP_MODE"

# 4) DEST: attendre champ destination (souvent sans id)
ui_wait_desc_any "destination field visible" "$WAIT_LONG" "destination" "arrivée" "Select destination"
ui_snap "05_destination_visible" "$SNAP_MODE"

# 5) DEST: tap champ
ui_tap_any "destination field" \
  "desc:destination" \
  "desc:arrivée" \
  "desc:Select destination" \
  "resid:$ID_TARGET" \
|| true
ui_refresh
ui_snap "06_after_tap_destination" "$SNAP_MODE"

# 6) DEST: taper + suggestions
ui_type_and_wait_results "destination" "$TARGET_TEXT"
ui_snap "07_after_type_destination" "$SNAP_MODE"

# 7) DEST: choisir suggestion
ui_pick_suggestion "destination suggestion" "$TARGET_TEXT"
ui_refresh
ui_snap "08_after_pick_destination" "$SNAP_MODE"

# 8) SEARCH: attendre bouton
ui_wait_search_button "$WAIT_LONG"
ui_snap "09_search_ready" "$SNAP_MODE"

# 9) SEARCH: tap bouton (ou ENTER)
if ! ui_tap_any "search button" \
  "resid:$ID_BTN_SEARCH_DEFAULT" \
  "resid:$ID_BTN_SEARCH" \
  "text:Rechercher" \
  "text:Itinéraires"
then
  warn "Search button not found -> ENTER fallback"
  maybe key 66 || true
fi

ui_snap_here "10_after_search" 3

# Heuristique de succès (optionnel)
latest_xml="$(ls -1t "$SNAP_DIR"/*.xml 2>/dev/null | head -n1 || true)"
if [[ -n "${latest_xml:-}" ]] && grep -qiE 'Results|Résultats|Itinéraire|Itinéraires|Trajet' "$latest_xml"; then
  log "Scenario success (keyword detected)"
  exit 0
fi

warn "Scenario ended without strong marker (not necessarily a failure)"
exit 0
