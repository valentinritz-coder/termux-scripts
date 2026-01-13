#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Summary (non-behavioral refactor only)
# - All comments and user-facing labels/messages are now in English.
# - All explicit log messages were renamed to a consistent structure:
#   "Phase: <phase> | Action: <action> | Target: <target> | Result: <result>"
# - Logging now always uses ISO-8601 timestamps with timezone:
#   2026-01-13T11:07:32+01:00 | INFO | ...
# - Snapshots are now named with a consistent convention and a runtime
#   sequential counter without holes:
#   <NNN>_<phase>__<action>__<state>
# - Note: renaming snapshot tags can break external tooling if it expects the
#   old snapshot filenames. Logic/flow is unchanged.
# ------------------------------------------------------------

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

# -------------------------
# Timestamped logging (ISO-8601 + timezone)
# -------------------------

_iso_ts() {
  local ts z
  ts="$(printf '%(%Y-%m-%dT%H:%M:%S)T' -1)"
  z="$(printf '%(%z)T' -1)" # e.g. +0100
  printf '%s%s:%s' "$ts" "${z:0:3}" "${z:3:2}"
}

_log_line() {
  local level="$1"
  shift
  local msg="$*"

  # Libraries sometimes emit: "wait ok: <label>"
  # If the label already starts with "Phase:", strip the library prefix
  # to keep a consistent structured message.
  if [[ "$msg" == "wait ok: Phase:"* ]]; then
    msg="${msg#wait ok: }"
  fi

  printf '%s | %s | %s\n' "$(_iso_ts)" "$level" "$msg"
}

log() {
  _log_line "INFO" "$@"
}

warn() {
  _log_line "WARN" "$@" >&2
}

# -------------------------
# Snapshot naming wrappers (sequential counter, no holes)
# Format: <NNN>_<phase>__<action>__<state>
# -------------------------

SNAP_SEQ=0

_snap_name() {
  local phase="$1" action="$2" state="$3"
  printf '%03d_%s__%s__%s' "$SNAP_SEQ" "$phase" "$action" "$state"
  SNAP_SEQ=$((SNAP_SEQ + 1))
}

snap() {
  local phase="$1" action="$2" state="$3" mode="$4"
  ui_snap "$(_snap_name "$phase" "$action" "$state")" "$mode"
}

snap_here() {
  local phase="$1" action="$2" state="$3" mode="$4"
  ui_snap_here "$(_snap_name "$phase" "$action" "$state")" "$mode"
}

snap_init "$run_name"

finish() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    warn "Phase: finish | Action: exit_trap | Target: run | Result: failed rc=$rc_open_viewer"
    "$CFL_CODE_DIR/lib/viewer.sh" "$SNAP_DIR" >/dev/null 2>&1 || true
    log "Phase: finish | Action: viewer | Target: snapshot_dir | Result: $SNAP_DIR/viewers/index.html"
  fi
  exit "$rc"
}
trap finish EXIT

# -------------------------
# Scenario
# -------------------------

log "Phase: launch | Action: scenario | Target: trip_planner | Result: start=$START_TEXT target=$TARGET_TEXT snap_mode=$SNAP_MODE"
if [[ -n "$VIA_TEXT_TRIM" ]]; then
  log "Phase: launch | Action: config | Target: via | Result: enabled value=$VIA_TEXT_TRIM"
else
  log "Phase: launch | Action: config | Target: via | Result: skipped empty"
fi

maybe cfl_launch

# -------------------------
# App ready
# -------------------------

log "Phase: launch | Action: wait | Target: toolbar | Result: requested"
ui_wait_desc_any "Phase: launch | Action: wait | Target: toolbar buttons | Result: visible" "Tab Notifications" "Tab Works" "Tab layout_itineraries_accessibility_label" "Tab Tickets" "Tab My C F L" "$WAIT_LONG"
snap "launch" "app_open" "visible" "$SNAP_MODE"

# -------------------------
# From Home → Trip Planner
# -------------------------

if ! ui_has_element "desc:Tab layout_itineraries_accessibility_label  selected" contains; then
  log "Phase: other tab | Action: tap itineraries tab | Target: itineraries tab | Result: itineraries tab selected"

  ui_tap_any "tab itineraries" \
    "desc:Tab layout_itineraries_accessibility_label" || true

  ui_wait_desc_any "Phase: launch | Action: wait | Target: from and to buttons | Result: visible" "From field" "To field" "$WAIT_LONG"
  snap "trip_planner" "trip_planner_menu" "after" "$SNAP_MODE"
fi

# -------------------------
# Trip Planner page
# -------------------------

if ! ui_has_element "desc:Tab layout_itineraries_accessibility_label  selected" contains; then
  warn "Phase: planner | Action: detect_page | Target: toolbar | Result: trip_planner_not_detected"
  snap_here "planner" "detect_page" "error" "$SNAP_MODE"
  exit 1
fi

log "Phase: planner | Action: detect_page | Target: toolbar | Result: trip_planner_visible"

# -------------------------
# Datetime (optional)
# -------------------------

if [[ -n "$DATE_YMD_TRIM" || -n "$TIME_HM_TRIM" ]]; then
  log "Phase: datetime | Action: set | Target: request | Result: requested date=$DATE_YMD_TRIM time=$TIME_HM_TRIM"

  # ---- Open Date/Time menu (CFL) ----
  if ui_has_element "desc:Time field" contains; then
    log "Phase: datetime | Action: tap | Target: time_field | Result: requested"
    ui_tap_any "open datetime menu" "desc:Time field"

    if ! ui_wait_desc_any \
      "Phase: datetime | Action: wait | Target: datetime_menu | Result: visible" \
      "Date," "Time," "Leave now" "$WAIT_LONG"; then
      warn "Phase: datetime | Action: open | Target: datetime_menu | Result: failed"
      exit 1
    fi
  else
    warn "Phase: datetime | Action: find | Target: time_field | Result: missing_skip"
    exit 0
  fi

  # ---------------------------------------------------------------------------
  # DATE
  # ---------------------------------------------------------------------------
  if [[ -n "$DATE_YMD_TRIM" ]]; then
    log "Phase: datetime | Action: set | Target: date | Result: requested value=$DATE_YMD_TRIM"

    ui_tap_any "open date picker" "desc:Date,"

    if ui_wait_desc_any \
      "Phase: datetime | Action: wait | Target: calendar | Result: visible" \
      "Previous month" "$WAIT_LONG"; then

      ui_calendar_set_date_ymd "$DATE_YMD_TRIM"

      log "Phase: datetime | Action: validate | Target: date | Result: ok"
      ui_tap_any "date ok" "resid:android:id/button1"

      # Retour menu CFL
      ui_wait_desc_any \
        "Phase: datetime | Action: wait | Target: datetime_menu | Result: back_visible" \
        "Date," "Time," "$WAIT_LONG"
    else
      warn "Phase: datetime | Action: set | Target: date | Result: calendar_not_visible"
    fi
  fi

  # ---------------------------------------------------------------------------
  # TIME
  # ---------------------------------------------------------------------------
  if [[ -n "$TIME_HM_TRIM" ]]; then
    log "Phase: datetime | Action: set | Target: time | Result: requested value=$TIME_HM_TRIM"

    ui_tap_any "open time picker" "desc:Time,"

    if ui_wait_resid \
      "Phase: datetime | Action: wait | Target: time_picker | Result: visible" \
      "android:id/input_hour" "$WAIT_LONG"; then

      # Passer en mode texte
      ui_tap_any "switch to text mode" "resid:android:id/toggle_mode"

      ui_wait_element_has_text \
        "Phase: datetime | Action: wait | Target: time_input | Result: text_mode" \
        "resid::id/top_label" "Type in time" "$WAIT_LONG"

      ui_datetime_set_time_12h_text "$TIME_HM_TRIM"

      log "Phase: datetime | Action: validate | Target: time | Result: ok"
      ui_tap_any "time ok" "resid:android:id/button1"

      # Retour menu CFL
      ui_wait_desc_any \
        "Phase: datetime | Action: wait | Target: datetime_menu | Result: back_visible" \
        "Date," "Time," "$WAIT_LONG"
    else
      warn "Phase: datetime | Action: set | Target: time | Result: time_picker_not_visible"
    fi
  fi

  # ---------------------------------------------------------------------------
  # APPLY (commit CFL)
  # ---------------------------------------------------------------------------
  if ui_has_element "desc:Apply" contains; then
    log "Phase: datetime | Action: apply | Target: cfl | Result: commit"
    snap "datetime" "apply" "before" "$SNAP_MODE"
    ui_tap_any "apply" "desc:Apply"
  else
    warn "Phase: datetime | Action: apply | Target: cfl | Result: missing_back_fallback"
    _ui_key 4 || true
  fi
fi


# -------------------------
# Start station
# -------------------------

log "Phase: planner | Action: set_start | Target: field | Result: begin"

ui_wait_resid "Phase: planner | Action: wait | Target: request_screen | Result: visible" ":id/request_screen_container" "$WAIT_LONG"
snap "planner" "set_start" "before" "$SNAP_MODE"

if ui_has_element "desc:Select start"; then
  log "Phase: planner | Action: open_field | Target: start | Result: empty_select_start"
  ui_tap_any "start field" "desc:Select start"
else
  log "Phase: planner | Action: open_field | Target: start | Result: filled_container_child"
  ui_tap_child_of_resid \
    "start field (container)" \
    ":id/request_screen_container" \
    0
fi

ui_wait_resid "Phase: planner | Action: wait | Target: input_location_name | Result: visible" ":id/input_location_name" "$WAIT_LONG"
ui_type_and_wait_results "start" "$START_TEXT"

# 1) Wait for keyboard to be shown (key detail)
_ui_wait_ime_shown || true
# 3) BACK (in your case: validate + close keyboard)
_ui_key 4 || true
# 4) Wait for keyboard to be fully hidden before tapping elsewhere
_ui_wait_ime_hidden || true

snap "planner" "set_start" "typed" "$SNAP_MODE"

if ! ui_pick_suggestion "start suggestion" "$START_TEXT"; then
  warn "Phase: planner | Action: pick_suggestion | Target: start | Result: not_found"
  exit 1
fi

snap "planner" "set_start" "selected" "$SNAP_MODE"

# -------------------------
# Destination station
# -------------------------

log "Phase: planner | Action: set_destination | Target: field | Result: begin"

ui_wait_resid "Phase: planner | Action: wait | Target: request_screen | Result: visible" ":id/request_screen_container" "$WAIT_LONG"
snap "planner" "set_destination" "before" "$SNAP_MODE"

if ui_has_element "desc:Select destination"; then
  log "Phase: planner | Action: open_field | Target: destination | Result: empty_select_destination"
  ui_tap_any "destination field" "desc:Select destination"
else
  log "Phase: planner | Action: open_field | Target: destination | Result: filled_container_child"
  ui_tap_child_of_resid \
    "destination field (container)" \
    ":id/request_screen_container" \
    2
fi

ui_wait_resid "Phase: planner | Action: wait | Target: input_location_name | Result: visible" ":id/input_location_name" "$WAIT_LONG"
ui_type_and_wait_results "destination" "$TARGET_TEXT"

# 1) Wait for keyboard to be shown (key detail)
_ui_wait_ime_shown || true
# 3) BACK (in your case: validate + close keyboard)
_ui_key 4 || true
# 4) Wait for keyboard to be fully hidden before tapping elsewhere
_ui_wait_ime_hidden || true

snap "planner" "set_destination" "typed" "$SNAP_MODE"

if ! ui_pick_suggestion "destination suggestion" "$TARGET_TEXT"; then
  warn "Phase: planner | Action: pick_suggestion | Target: destination | Result: not_found"
  exit 1
fi

snap "planner" "set_destination" "selected" "$SNAP_MODE"

# -------------------------
# VIA (optional)
# -------------------------

if [[ -n "$VIA_TEXT_TRIM" ]]; then
  log "Phase: planner | Action: set_via | Target: field | Result: begin value=$VIA_TEXT_TRIM"

  if ui_wait_resid "Phase: planner | Action: wait | Target: options_button | Result: visible" ":id/button_options" "$WAIT_LONG"; then
    ui_tap_any "options button" \
      "desc:Extended search options" \
      "resid::id/button_options" || true

    snap_here "planner" "open_options" "after" "$SNAP_MODE"

    if ui_wait_resid "Phase: planner | Action: wait | Target: via_field | Result: visible" ":id/input_via" "$WAIT_LONG"; then
      ui_tap_any "via field" \
        "text:Enter stop" \
        "resid::id/input_via" || true

      snap_here "planner" "set_via" "field_open" "$SNAP_MODE"

      ui_type_and_wait_results "via" "$VIA_TEXT_TRIM"

      # 1) Wait for keyboard to be shown (key detail)
      _ui_wait_ime_shown || true
      # 3) BACK (in your case: validate + close keyboard)
      _ui_key 4 || true
      # 4) Wait for keyboard to be fully hidden before tapping elsewhere
      _ui_wait_ime_hidden || true

      snap "planner" "set_via" "typed" "$SNAP_MODE"

      ui_pick_suggestion "via suggestion" "$VIA_TEXT_TRIM" || true
      snap "planner" "set_via" "selected" "$SNAP_MODE"

      ui_tap_any "back from via" "desc:Navigate up" || true
      snap_here "planner" "exit_options" "after" "$SNAP_MODE"
    else
      warn "Phase: planner | Action: find_field | Target: via | Result: not_found_skip"
    fi
  else
    warn "Phase: planner | Action: find_button | Target: options | Result: not_found_skip_via"
  fi
fi

# -------------------------
# Search
# -------------------------

ui_wait_resid "Phase: planner | Action: wait | Target: search_button | Result: visible" ":id/button_search_default" "$WAIT_LONG"

if ! ui_tap_any "search button" \
  "resid::id/button_search_default"; then
  warn "Phase: planner | Action: tap | Target: search_button | Result: not_tappable_enter_fallback"
  maybe key 66 || true
fi

snap_here "results" "search" "after" 3

# -------------------------
# Drill all visible connections
# -------------------------

log "Phase: results | Action: search | Target: request | Result: started"

ui_wait_resid "Phase: results | Action: wait | Target: results_page | Result: visible" ":id/haf_connection_view" "$WAIT_LONG"

log "Phase: results | Action: drill_connections | Target: haf_connection_view | Result: begin"

declare -A SEEN_CONNECTIONS

scrolls=0
final_pass=0

while true; do
  ui_refresh
  mapfile -t ITEMS < <(ui_list_resid_desc_bounds ":id/haf_connection_view")
  log "Phase: results | Action: debug_items | Target: haf_connection_view | Result: count=${#ITEMS[@]}"

  for i in "${!ITEMS[@]}"; do
    # %q prints an escaped representation (tabs, spaces, etc.)
    log "Phase: results | Action: debug_item | Target: haf_connection_view | Result: index=$i item=$(printf '%q' "${ITEMS[$i]}")"
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

    log "Phase: results | Action: open_connection | Target: haf_connection_view | Result: tap"
    ui_tap_xy "connection" "$cx" "$cy"

    if ! ui_wait_resid "Phase: results | Action: wait | Target: connection_details | Result: visible" ":id/text_line_name" "$WAIT_LONG"; then
      warn "Phase: results | Action: open_connection | Target: connection_details | Result: not_opened_retry"
      continue
    fi

    # ---- mark SEEN only after success ----
    SEEN_CONNECTIONS["$key"]=1
    new=1

    snap "results" "open_connection" "details_visible" 3

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

        log "Phase: results | Action: open_route | Target: route_list | Result: tap text=$text"
        ui_tap_xy "route" "$rcx" "$rcy"

        if ! ui_wait_resid "Phase: results | Action: wait | Target: route_details | Result: visible" ":id/journey_details_head" "$WAIT_LONG"; then
          warn "Phase: results | Action: open_route | Target: route_details | Result: not_opened_retry"
          continue
        fi

        SEEN_ROUTES["$rkey"]=1
        rnew=1

        ui_scrollshot_region "route_${rkey}" ":id/journey_details_head"
        log "Phase: results | Action: scrollshot | Target: route | Result: captured name=route_${rkey}"
        sleep_s 0.3

        _ui_key 4 || true
        ui_wait_resid "Phase: results | Action: wait | Target: connection_details | Result: visible" ":id/text_line_name" "$WAIT_LONG"
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
    ui_wait_resid "Phase: results | Action: wait | Target: results_page | Result: visible" ":id/haf_connection_view" "$WAIT_LONG"
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
  log "Phase: finish | Action: heuristic | Target: latest_xml | Result: success_keyword_detected"
  exit 0
fi

# warn "Scenario ended without strong marker (not necessarily a failure)"
exit 0
