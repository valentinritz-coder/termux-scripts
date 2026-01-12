#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# CFL trip scenario (API version, readable)
# Env: START_TEXT, TARGET_TEXT, VIA_TEXT (optional), SNAP_MODE, WAIT_*, CFL_DRY_RUN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

SNAP_MODE_SET=0
if [ "${SNAP_MODE+set}" = "set" ]; then
  SNAP_MODE_SET=1
fi

CFL_CODE_DIR="${CFL_CODE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CFL_CODE_DIR="$(expand_tilde_path "$CFL_CODE_DIR")"
CFL_BASE_DIR="${CFL_BASE_DIR:-$CFL_CODE_DIR}"

# Load env overrides (optional)
if [ -f "$CFL_CODE_DIR/env.sh" ]; then
  . "$CFL_CODE_DIR/env.sh"
fi
if [ -f "$CFL_CODE_DIR/env.local.sh" ]; then
  . "$CFL_CODE_DIR/env.local.sh"
fi

# Re-resolve after env (in case env overrides CFL_CODE_DIR)
CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}")"
CFL_BASE_DIR="${CFL_BASE_DIR:-$CFL_CODE_DIR}"

. "$CFL_CODE_DIR/lib/common.sh"
. "$CFL_CODE_DIR/lib/snap.sh"

need python

# UI libs
. "$CFL_CODE_DIR/lib/ui_core.sh"
. "$CFL_CODE_DIR/lib/ui_select.sh"
. "$CFL_CODE_DIR/lib/ui_api.sh"
. "$CFL_CODE_DIR/lib/ui_datetime.sh"


# Inputs
START_TEXT="${START_TEXT:-LUXEMBOURG}"
TARGET_TEXT="${TARGET_TEXT:-ARLON}"

# VIA is optional: empty/undefined => skip
VIA_TEXT="${VIA_TEXT:-}"
VIA_TEXT_TRIM="$(printf '%s' "$VIA_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

if [ "$SNAP_MODE_SET" -eq 0 ]; then
  SNAP_MODE=2   # 2 = xml only (fast), 3 = xml+png (slower)
fi

# Date and time
DATE_YMD="${DATE_YMD:-}"
TIME_HM="${TIME_HM:-}"
DATE_YMD_TRIM="$(printf '%s' "$DATE_YMD" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
TIME_HM_TRIM="$(printf '%s' "$TIME_HM" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

# waits
WAIT_POLL="${WAIT_POLL:-0.0}"
WAIT_SHORT="${WAIT_SHORT:-20}"
WAIT_LONG="${WAIT_LONG:-30}"

# Snap run name
# Snap run name
run_name="trip_$(safe_name "$START_TEXT")_to_$(safe_name "$TARGET_TEXT")"
if [[ -n "$VIA_TEXT_TRIM" ]]; then
  run_name="${run_name}_via_$(safe_name "$VIA_TEXT_TRIM")"
fi
if [[ -n "$DATE_YMD_TRIM" ]]; then
  run_name="${run_name}_d_$(safe_name "$DATE_YMD_TRIM")"
fi
if [[ -n "$TIME_HM_TRIM" ]]; then
  run_name="${run_name}_t_$(safe_name "$TIME_HM_TRIM")"
fi

log() {
  local msg="$*"
  printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$msg"
}

snap_init "$run_name"

finish() {
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
# Scenario
# -------------------------

log "Scenario: $START_TEXT -> $TARGET_TEXT (SNAP_MODE=$SNAP_MODE)"
if [[ -n "$VIA_TEXT_TRIM" ]]; then
  log "VIA enabled: $VIA_TEXT_TRIM"
else
  log "VIA skipped (VIA_TEXT empty)"
fi

maybe cfl_launch

log "Wait toolbar visible"
ui_wait_resid "toolbar visible" ":id/toolbar" "$WAIT_LONG"

ui_snap "000_opening" "$SNAP_MODE"

# -------------------------
# From Home → Trip Planner
# -------------------------
if ui_element_has_text "resid::id/toolbar" "Home"; then
  log "Toolbar affiche Home"

  ui_tap_any "burger icon tap" \
    "desc:Show navigation drawer" || true

  ui_wait_resid "drawer visible" ":id/left_drawer" "$WAIT_LONG"
  ui_snap "001_after_tap_burger" "$SNAP_MODE"

  ui_tap_any "trip planner menu" \
    "text:Trip Planner" || true

  ui_wait_element_has_text \
    "wait trip planner page" \
    "resid::id/toolbar" \
    "Trip Planner" \
    "$WAIT_LONG"
fi

# -------------------------
# Trip Planner page logic
# -------------------------
if ! ui_element_has_text "resid::id/toolbar" "Trip Planner"; then
  warn "Trip Planner page not detected"
  return 1
fi

log "Toolbar affiche Trip Planner"

# ---- Datetime (optionnel)
if [[ -n "$DATE_YMD_TRIM" || -n "$TIME_HM_TRIM" ]]; then
  log "Réglage de la date et de l'heure"

  if ui_has_element "resid::id/datetime_text"; then
    ui_tap_any "date time field" "resid::id/datetime_text"

    if ui_wait_resid "time picker visible" ":id/picker_time" "$WAIT_LONG"; then
      [[ -n "$DATE_YMD_TRIM" ]] && ui_datetime_set_date_ymd "$DATE_YMD_TRIM"
      [[ -n "$TIME_HM_TRIM"  ]] && ui_datetime_set_time_24h "$TIME_HM_TRIM"

      if ui_has_element "resid::id/button1"; then
        ui_snap "020_after_set_datetime" "$SNAP_MODE"
        ui_tap_any "OK button" "resid:android:id/button1"
      else
        _ui_key 4 || true
        warn "Datetime dialog not validated → back fallback"
      fi
    else
      warn "Datetime dialog not opened → skipping"
    fi
  else
    warn "Date/Time field absent → skip datetime"
  fi
fi

# ---- Station de départ
log "Réglage de la station de départ"

# On attend que l'écran de requête soit là
ui_wait_resid "request screen visible" \
  ":id/request_screen_container" \
  "$WAIT_LONG"

ui_snap "030_before_set_start" "$SNAP_MODE"

# Cas 1: champ vide → Select start visible directement
if ui_has_element "desc:Select start"; then
  log "Start field empty → using Select start"
  ui_tap_any "start field" "desc:Select start"

# Cas 2: champ déjà rempli → structure container
elif ui_has_element "resid::id/request_screen_container"; then
  log "Start field already filled → using first child of container"
  ui_tap_child_of_resid \
    "start field (container)" \
    ":id/request_screen_container" \
    0 \
    clickable
else
  warn "Start field not found"
  return 1
fi

# Champ de saisie
ui_wait_resid "input location name visible" ":id/input_location_name" "$WAIT_LONG"

ui_type_and_wait_results "start" "$START_TEXT"
ui_snap "031_after_type_start" "$SNAP_MODE"

# Choix suggestion
if ! ui_pick_suggestion "start suggestion" "$START_TEXT"; then
  warn "Start suggestion not found"
  return 1
fi

ui_snap "032_after_pick_start" "$SNAP_MODE"























ui_wait_desc_any "start field visible" "Select start" "$WAIT_LONG"
ui_snap "030_before_set_start" "$SNAP_MODE"

if ! ui_tap_any "start field" "desc:Select start"; then
  warn "Start field not tappable"
  return 1
fi

ui_wait_resid "input location name visible" ":id/input_location_name" "$WAIT_LONG"
ui_type_and_wait_results "start" "$START_TEXT"
ui_snap "031_after_type_start" "$SNAP_MODE"

if ! ui_pick_suggestion "start suggestion" "$START_TEXT"; then
  warn "Start suggestion not found"
  return 1
fi

ui_snap "032_after_pick_start" "$SNAP_MODE"











  
  log "Réglage de la station de départ"
  ui_wait_desc_any "start field visible" "$WAIT_LONG" "Select start"
  ui_snap "030_before_set_start" "$SNAP_MODE"

  if ui_has_element "desc:Select start"; then 
    ui_tap_any "start field" "desc:Select start"
    ui_wait_resid "input location name visible" ":id/input_location_name" "$WAIT_LONG"
    if ui_has_element "resid::id/input_location_name"; then 
      ui_type_and_wait_results "start" "$START_TEXT"
      ui_snap "03_after_type_start" "$SNAP_MODE"
      # 3) START: choisir suggestion
      ui_pick_suggestion "start suggestion" "$START_TEXT"

      ui_snap "04_after_pick_start" "$SNAP_MODE"
    else
      warn "Issue with selection start"
    fi
  else
    warn "Issue with selection start field"
  fi
    
  ui_wait_desc_any "destination field visible" "$WAIT_LONG" "Select destination"
  ui_snap "030_before_set_destination" "$SNAP_MODE"
  if ui_has_element "desc:Select destination"; then 
    ui_tap_any "start field" "desc:Select destination"
    ui_wait_resid "input location name visible" ":id/input_location_name" "$WAIT_LONG"
    if ui_has_element "resid::id/input_location_name"; then 
      ui_type_and_wait_results "destination" "$TARGET_TEXT"
      ui_snap "03_after_type_destination" "$SNAP_MODE"
      # 3) START: choisir suggestion
      ui_pick_suggestion "destination suggestion" "$TARGET_TEXT"

      ui_snap "04_after_pick_destination" "$SNAP_MODE"
    else
      warn "Issue with selection destination"
    fi
  else
    warn "Issue with selection destination field"
  fi
  
  # VIA (optional)
  if [[ -n "$VIA_TEXT_TRIM" ]]; then
  # attendre bouton options
  if ui_wait_resid "options button visible" "$ID_SETTING" "$WAIT_LONG"; then
    # tap options
    ui_tap_any "options button" \
      "desc:Extended search options" \
      "resid:$ID_SETTING" \
    || true
    ui_snap_here "08a_after_open_options" "$SNAP_MODE"
  
    # attendre champ via
    if ui_wait_resid "via field visible" "$ID_VIA" "$WAIT_LONG"; then
      # tap champ via
      ui_tap_any "tap via field" \
        "text:Enter stop" \
        "resid:$ID_VIA" \
      || true
      ui_snap_here "08b_after_tap_via" "$SNAP_MODE"
  
      # taper + suggestions
      ui_type_and_wait_results "via" "$VIA_TEXT_TRIM"
      ui_snap "08c_after_type_via" "$SNAP_MODE"
  
      # choisir suggestion
      ui_pick_suggestion "via suggestion" "$VIA_TEXT_TRIM"
      ui_refresh
      ui_snap "08d_after_pick_via" "$SNAP_MODE"
  
      # revenir (navigate up)
      ui_tap_any "tap back button" \
        "desc:Navigate up" \
      || true
      ui_snap_here "08e_after_back_from_via" "$SNAP_MODE"
    else
      warn "VIA enabled but via field not found -> skipping VIA"
    fi
  else
    warn "VIA enabled but options button not found -> skipping VIA"
  fi
  fi
  
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
  
  # Force xml+png after search for debugging even if SNAP_MODE=2
  ui_snap_here "10_after_search" 3
  
  # Heuristique de succès (optionnel)
  latest_xml="$(ls -1t "$SNAP_DIR"/*.xml 2>/dev/null | head -n1 || true)"
  if [[ -n "${latest_xml:-}" ]] && grep -qiE 'Results|Résultats|Itinéraire|Itinéraires|Trajet' "$latest_xml"; then
  log "Scenario success (keyword detected)"
  exit 0
  fi
else
  warn "Toolbar dans un état inattendu"
  ui_snap_here "toolbar_unexpected_state" "$SNAP_MODE"
fi

warn "Scenario ended without strong marker (not necessarily a failure)"
exit 0
