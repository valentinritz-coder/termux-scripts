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
. "$CFL_CODE_DIR/lib/ui_scrollshot.sh"

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

# -------------------------
# App ready
# -------------------------

log "Wait toolbar visible"
ui_wait_resid "toolbar visible" ":id/toolbar" "$WAIT_LONG"
ui_snap "app_opening" "$SNAP_MODE"

# -------------------------
# From Home → Trip Planner
# -------------------------

if ui_element_has_text "resid::id/toolbar" "Home"; then
  log "toolbar_show_home"

  ui_tap_any "burger icon tap" \
    "desc:Show navigation drawer" || true

  ui_wait_resid "drawer visible" ":id/left_drawer" "$WAIT_LONG"
  ui_snap "burger_button_tap" "$SNAP_MODE"

  ui_tap_any "trip_planner_button_tap" \
    "text:Trip Planner" || true

  ui_wait_element_has_text \
    "wait_trip_planner_page" \
    "resid::id/toolbar" \
    "Trip Planner" \
    "$WAIT_LONG"
fi

# -------------------------
# Trip Planner page
# -------------------------

if ! ui_element_has_text "resid::id/toolbar" "Trip Planner"; then
  warn "trip_planner_page_not_detected"
  ui_snap_here "trip_planner_page_not_detected" "$SNAP_MODE"
  exit 1
fi

log "toolbar_show_trip_planner"

# -------------------------
# Datetime (optional)
# -------------------------

if [[ -n "$DATE_YMD_TRIM" || -n "$TIME_HM_TRIM" ]]; then
  log "setting_date_and_time"

  if ui_has_element "resid::id/datetime_text"; then
    ui_tap_any "date_time_button_tap" "resid::id/datetime_text"

    if ui_wait_resid "wait_time_picker" ":id/picker_time" "$WAIT_LONG"; then
      [[ -n "$DATE_YMD_TRIM" ]] && ui_datetime_set_date_ymd "$DATE_YMD_TRIM"
      [[ -n "$TIME_HM_TRIM"  ]] && ui_datetime_set_time_24h "$TIME_HM_TRIM"

      if ui_has_element "resid::id/button1"; then
        ui_snap "setting_date_and_time" "$SNAP_MODE"
        ui_tap_any "ok_button_tap" "resid:android:id/button1"
      else
        _ui_key 4 || true
        warn "Datetime dialog not validated → back fallback"
      fi
    else
      warn "Datetime dialog not opened → skipping datetime"
    fi
  else
    warn "Date/Time field absent → skip datetime"
  fi
fi

# -------------------------
# Start station
# -------------------------

log "Réglage de la station de départ"

ui_wait_resid "request screen visible" ":id/request_screen_container" "$WAIT_LONG"
ui_snap "030_before_set_start" "$SNAP_MODE"

if ui_has_element "desc:Select start"; then
  log "Start field empty → Select start"
  ui_tap_any "start field" "desc:Select start"
else
  log "Start field filled → container child"
  ui_tap_child_of_resid \
    "start field (container)" \
    ":id/request_screen_container" \
    0
fi

ui_wait_resid "input location name visible" ":id/input_location_name" "$WAIT_LONG"
ui_type_and_wait_results "start" "$START_TEXT"
# 1) attendre que le clavier soit là (ton point clé)
_ui_wait_ime_shown || true
# 3) BACK (chez toi: valide + ferme clavier)
_ui_key 4 || true
# 4) attendre que le clavier soit vraiment parti avant de re-cliquer ailleurs
_ui_wait_ime_hidden || true
ui_snap "031_after_type_start" "$SNAP_MODE"

if ! ui_pick_suggestion "start suggestion" "$START_TEXT"; then
  warn "Start suggestion not found"
  exit 1
fi

ui_snap "032_after_pick_start" "$SNAP_MODE"

# -------------------------
# Destination station
# -------------------------

log "Réglage de la station de destination"

ui_wait_resid "request screen visible" ":id/request_screen_container" "$WAIT_LONG"
ui_snap "040_before_set_destination" "$SNAP_MODE"

if ui_has_element "desc:Select destination"; then
  log "Destination field empty → Select destination"
  ui_tap_any "destination field" "desc:Select destination"
else
  log "Destination field filled → container child"
  ui_tap_child_of_resid \
    "destination field (container)" \
    ":id/request_screen_container" \
    2
fi

ui_wait_resid "input location name visible" ":id/input_location_name" "$WAIT_LONG"
ui_type_and_wait_results "destination" "$TARGET_TEXT"
# 1) attendre que le clavier soit là (ton point clé)
_ui_wait_ime_shown || true
# 3) BACK (chez toi: valide + ferme clavier)
_ui_key 4 || true
# 4) attendre que le clavier soit vraiment parti avant de re-cliquer ailleurs
_ui_wait_ime_hidden || true
ui_snap "041_after_type_destination" "$SNAP_MODE"

if ! ui_pick_suggestion "destination suggestion" "$TARGET_TEXT"; then
  warn "Destination suggestion not found"
  exit 1
fi

ui_snap "042_after_pick_destination" "$SNAP_MODE"

# -------------------------
# VIA (optional)
# -------------------------

if [[ -n "$VIA_TEXT_TRIM" ]]; then
  log "Réglage de la station VIA"

  if ui_wait_resid "options button visible" ":id/button_options" "$WAIT_LONG"; then
    ui_tap_any "options button" \
      "desc:Extended search options" \
      "resid::id/button_options" || true

    ui_snap_here "050_after_open_options" "$SNAP_MODE"

    if ui_wait_resid "via field visible" ":id/input_via" "$WAIT_LONG"; then
      ui_tap_any "via field" \
        "text:Enter stop" \
        "resid::id/input_via" || true

      ui_snap_here "051_after_tap_via" "$SNAP_MODE"

      ui_type_and_wait_results "via" "$VIA_TEXT_TRIM"
      # 1) attendre que le clavier soit là (ton point clé)
      _ui_wait_ime_shown || true
      # 3) BACK (chez toi: valide + ferme clavier)
      _ui_key 4 || true
      # 4) attendre que le clavier soit vraiment parti avant de re-cliquer ailleurs
      _ui_wait_ime_hidden || true
      ui_snap "052_after_type_via" "$SNAP_MODE"

      ui_pick_suggestion "via suggestion" "$VIA_TEXT_TRIM" || true
      ui_snap "053_after_pick_via" "$SNAP_MODE"

      ui_tap_any "back from via" "desc:Navigate up" || true
      ui_snap_here "054_after_back_from_via" "$SNAP_MODE"
    else
      warn "VIA field not found → skipping VIA"
    fi
  else
    warn "Options button not found → skipping VIA"
  fi
fi

# -------------------------
# Search
# -------------------------

ui_wait_resid "search button visible" ":id/button_search_default" "$WAIT_LONG"

if ! ui_tap_any "search button" \
  "resid::id/button_search_default"; then
  warn "Search button not tappable → ENTER fallback"
  maybe key 66 || true
fi

ui_snap_here "060_after_search" 3

# -------------------------
# Drill all visible connections
# -------------------------

log "Lancement de la recherche"

ui_wait_resid "results page visible" ":id/haf_connection_view" "$WAIT_LONG"

log "Drill connections (content-desc driven)"

declare -A SEEN_CONNECTIONS

scrolls=0
final_pass=0

while true; do
  ui_refresh
  mapfile -t ITEMS < <(ui_list_resid_desc_bounds ":id/haf_connection_view")
  log "ITEMS count=${#ITEMS[@]}"

  for i in "${!ITEMS[@]}"; do
    # %q affiche une version échappée (tabs, espaces, etc.)
    log "ITEMS[$i]=$(printf '%q' "${ITEMS[$i]}")"
  done

  new=0

  for item in "${ITEMS[@]}"; do
    IFS=$'\t' read -r desc bounds <<<"$item"

    raw_key="$desc"
    key="$(hash_key "$raw_key")"

    [[ -n "${SEEN_CONNECTIONS[$key]:-}" ]] && continue

    # ---- compute tap coords ----
    [[ "$bounds" =~ \[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\] ]] || continue
    cx=$(( (BASH_REMATCH[1] + BASH_REMATCH[3]) / 2 ))
    cy=$(( (BASH_REMATCH[2] + BASH_REMATCH[4]) / 2 ))

    log "Open connection"
    ui_tap_xy "connection" "$cx" "$cy"

    if ! ui_wait_resid "details page" ":id/text_line_name" "$WAIT_LONG"; then
      warn "Connection not opened, retry later"
      continue
    fi

    # ---- mark SEEN only after success ----
    SEEN_CONNECTIONS["$key"]=1
    new=1

    ui_snap "070_connection" 3

    # -------------------------
    # Drill routes
    # -------------------------

    declare -A SEEN_ROUTES
    route_scrolls=0
    route_final_pass=0

    while true; do
      ui_refresh
      mapfile -t ROUTES < <(ui_list_resid_text_bounds ":id/text_line_name")

      rnew=0

      for r in "${ROUTES[@]}"; do
        IFS=$'\t' read -r text rbounds <<<"$r"

        raw_rkey="$text"
        rkey="$(hash_key "$raw_rkey")"

        [[ -n "${SEEN_ROUTES[$rkey]:-}" ]] && continue

        [[ "$rbounds" =~ \[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\] ]] || continue
        rcx=$(( (BASH_REMATCH[1] + BASH_REMATCH[3]) / 2 ))
        rcy=$(( (BASH_REMATCH[2] + BASH_REMATCH[4]) / 2 ))

        log "Open route: $text"
        ui_tap_xy "route" "$rcx" "$rcy"

        if ! ui_wait_resid "route details" ":id/journey_details_head" "$WAIT_LONG"; then
          warn "Route not opened, retry later"
          continue
        fi

        SEEN_ROUTES["$rkey"]=1
        rnew=1

        ui_scrollshot_region "route_${rkey}" ":id/journey_details_head"
        log "route scrollshot captured for route_${rkey}"
        sleep_s 0.3

        _ui_key 4 || true
        ui_wait_resid "back to details" ":id/text_line_name" "$WAIT_LONG"
      done

      if [[ $rnew -eq 0 ]]; then
        if [[ $route_final_pass -eq 1 ]]; then
          break
        fi
        route_final_pass=1
      else
        route_final_pass=0
      fi

      route_scrolls=$((route_scrolls + 1))
      [[ $route_scrolls -ge 8 ]] && break

      ui_scroll_down
      sleep_s 0.4
    done

    # ---- back to results ----
    _ui_key 4 || true
    ui_wait_resid "back to results" ":id/haf_connection_view" "$WAIT_LONG"
  done

  if [[ $new -eq 0 ]]; then
    if [[ $final_pass -eq 1 ]]; then
      break
    fi
    final_pass=1
  else
    final_pass=0
  fi

  scrolls=$((scrolls + 1))
  [[ $scrolls -ge 10 ]] && break

  ui_scroll_down
  sleep_s 0.4
done

# -------------------------
# End heuristic (soft)
# -------------------------

latest_xml="$(ls -1t "$SNAP_DIR"/*.xml 2>/dev/null | head -n1 || true)"
if [[ -n "$latest_xml" ]] && grep -qiE 'Results|Résultats|Itinéraire|Itinéraires|Trajet' "$latest_xml"; then
  log "Scenario success (keyword detected)"
  exit 0
fi

#warn "Scenario ended without strong marker (not necessarily a failure)"
exit 0
