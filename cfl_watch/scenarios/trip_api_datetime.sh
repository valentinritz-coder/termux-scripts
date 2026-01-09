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

# IDs (suffix) used by ui_wait_search_button
ID_START=":id/input_start"
ID_TARGET=":id/input_target"
ID_SETTING=":id/button_options"
ID_VIA=":id/input_via"
ID_DATETIME=":id/datetime_text"
ID_BTN_SEARCH=":id/button_search"
ID_BTN_SEARCH_DEFAULT=":id/button_search_default"

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



# 7b) Règle la date
if [[ -n "$DATE_YMD_TRIM" || -n "$TIME_HM_TRIM" ]]; then
  #ui_refresh
  #ui_snap "08f_before_open_datetime" "$SNAP_MODE"

  # Optionnel: si Now existe sur l'écran principal et sert à activer/remplir le champ
  #if ui_tap_any "preset now (optional)" "resid::button_now" "text:Now" ; then
  #  #ui_refresh
  #fi

  # Ouvre le dialog UNE fois
  ui_tap_any "date time field" "resid:$ID_DATETIME" || true

  if ui_datetime_wait_dialog "$WAIT_LONG"; then
    #ui_datetime_lock_dialog_xml || true
  
    if [[ -n "$DATE_YMD_TRIM" ]]; then
      ui_datetime_set_date_ymd "$DATE_YMD_TRIM"
    fi
    if [[ -n "$TIME_HM_TRIM" ]]; then
      ui_datetime_set_time_24h "$TIME_HM_TRIM"
    fi
    ui_datetime_ok
    ui_snap_here "08g_after_datetime_ok" "$SNAP_MODE"
  else
    warn "Datetime dialog not opened -> skipping datetime"
  fi
fi












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

warn "Scenario ended without strong marker (not necessarily a failure)"
exit 0
