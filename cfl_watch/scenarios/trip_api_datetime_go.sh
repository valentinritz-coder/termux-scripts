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

rc_open_viewer=0

finish() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    warn "Phase: finish | Action: exit_trap | Target: run | Result: failed rc=${rc_open_viewer:-0}"
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
# Start station (search modal)
# -------------------------

# Wait toolbar buttons visible (same call, explicit failure handling)
if ui_wait_desc_any "Phase: launch | Action: wait | Target: toolbar buttons | Result: visible" "From field." "$WAIT_LONG"; then
  :
else
  rc=$?
  warn "Phase: launch | Action: wait | Target: toolbar buttons | Result: timeout"
  exit $rc
fi

# Field may already be active depending on previous state (same call, still best-effort)
if ui_tap_any "PAGE START" "desc:From field."; then
  :
else
  # was: || true
  log "Phase: launch | Action: tap | Target: from_field | Result: skipped"
fi

log "Phase: planner | Action: set_start | Target: from | Result: begin"

# Wait for search modal title (strong anchor) (same call, explicit failure handling)
if ui_wait_resid "Phase: planner | Action: wait | Target: from_modal | Result: visible" "fromModalTitle" "$WAIT_LONG"; then
  :
else
  rc=$?
  warn "Phase: planner | Action: wait | Target: from_modal | Result: timeout"
  exit $rc
fi

snap "planner" "set_start" "modal_visible" "$SNAP_MODE"

# Focus input field
log "Phase: planner | Action: focus | Target: from_input"

# Retour menu CFL (same call, explicit failure handling)
if ui_wait_resid "Phase: planner | Action: wait | Target: from_field | Result: visible" "fromInputSearch" "$WAIT_LONG"; then
  :
else
  rc=$?
  warn "Phase: planner | Action: wait | Target: from_field | Result: timeout"
  exit $rc
fi

# Tap input (same call; if it fails, we exit with the same rc as before under set -e)
if ui_tap_any "select from field" "resid:fromInputSearch"; then
  :
else
  rc=$?
  warn "Phase: planner | Action: tap | Target: from_input | Result: failed"
  exit $rc
fi

# Type text (same call; explicit failure handling without changing behavior)
if ui_type "from" "$START_TEXT"; then
  :
else
  rc=$?
  warn "Phase: planner | Action: type | Target: from_input | Result: failed"
  exit $rc
fi

snap "planner" "set_start" "typed" "$SNAP_MODE"

# 1) Wait for keyboard to be shown (was: || true)
if _ui_wait_ime_shown; then
  :
else
  log "Phase: planner | Action: ime_wait | Target: keyboard | Result: not_detected"
fi

# 3) BACK (was: || true)
if _ui_key 4; then
  :
else
  log "Phase: planner | Action: key | Target: back | Result: failed"
fi

# 4) Wait for keyboard to be fully hidden (was: || true)
if _ui_wait_ime_hidden; then
  :
else
  log "Phase: planner | Action: ime_wait | Target: keyboard | Result: not_hidden_or_unknown"
fi

# Wait for at least one suggestion matching START_TEXT (unchanged logic)
if ! ui_wait_desc_any "Phase: planner | Action: wait | Target: start_suggestion | Result: visible" "$START_TEXT"; then
  warn "Phase: planner | Action: wait | Target: start_suggestion | Result: timeout"
  exit 1
fi

# Pick first matching suggestion (unchanged logic)
if ! ui_tap_desc "start suggestion" "$START_TEXT,"; then
  warn "Phase: planner | Action: pick | Target: start | Result: not_found"
  exit 1
fi

snap "planner" "set_start" "selected" "$SNAP_MODE"

log "Phase: planner | Action: set_start | Target: from | Result: done"


# -------------------------
# Destination station (search modal)
# -------------------------

# Wait toolbar buttons visible (same call, explicit failure handling)
if ui_wait_desc_any "Phase: launch | Action: wait | Target: toolbar buttons | Result: visible" "To field." "$WAIT_LONG"; then
  :
else
  rc=$?
  warn "Phase: launch | Action: wait | Target: toolbar buttons | Result: timeout"
  exit $rc
fi

# Field may already be active depending on previous state (same call, still best-effort)
if ui_tap_any "PAGE DESTINATION" "desc:To field."; then
  :
else
  # was: || true
  log "Phase: launch | Action: tap | Target: to_field | Result: skipped"
fi

log "Phase: planner | Action: set_destination | Target: to | Result: begin"

# Wait for search modal title (strong anchor) (same call, explicit failure handling)
if ui_wait_resid "Phase: planner | Action: wait | Target: to_modal | Result: visible" "toModalTitle" "$WAIT_LONG"; then
  :
else
  rc=$?
  warn "Phase: planner | Action: wait | Target: to_modal | Result: timeout"
  exit $rc
fi

snap "planner" "set_destination" "modal_visible" "$SNAP_MODE"

# Focus input field
log "Phase: planner | Action: focus | Target: to_input"

# Retour menu CFL (same call, explicit failure handling)
if ui_wait_resid "Phase: planner | Action: wait | Target: to_field | Result: visible" "toInputSearch" "$WAIT_LONG"; then
  :
else
  rc=$?
  warn "Phase: planner | Action: wait | Target: to_field | Result: timeout"
  exit $rc
fi

# Tap input (same call; if it fails, we exit with the same rc as before under set -e)
if ui_tap_any "select to field" "resid:toInputSearch"; then
  :
else
  rc=$?
  warn "Phase: planner | Action: tap | Target: to_input | Result: failed"
  exit $rc
fi

# Type text (same call; explicit failure handling without changing behavior)
if ui_type "to" "$TARGET_TEXT"; then
  :
else
  rc=$?
  warn "Phase: planner | Action: type | Target: to_input | Result: failed"
  exit $rc
fi

snap "planner" "set_destination" "typed" "$SNAP_MODE"

# 1) Wait for keyboard to be shown (was: || true)
if _ui_wait_ime_shown; then
  :
else
  log "Phase: planner | Action: ime_wait | Target: keyboard | Result: not_detected"
fi

# 3) BACK (was: || true)
if _ui_key 4; then
  :
else
  log "Phase: planner | Action: key | Target: back | Result: failed"
fi

# 4) Wait for keyboard to be fully hidden (was: || true)
if _ui_wait_ime_hidden; then
  :
else
  log "Phase: planner | Action: ime_wait | Target: keyboard | Result: not_hidden_or_unknown"
fi

# Wait for at least one suggestion matching TARGET_TEXT (unchanged logic)
if ! ui_wait_desc_any "Phase: planner | Action: wait | Target: destination_suggestion | Result: visible" "$TARGET_TEXT"; then
  warn "Phase: planner | Action: wait | Target: destination_suggestion | Result: timeout"
  exit 1
fi

# Pick first matching suggestion (unchanged logic)
if ! ui_tap_desc "destination suggestion" "$TARGET_TEXT,"; then
  warn "Phase: planner | Action: pick | Target: destination | Result: not_found"
  exit 1
fi

snap "planner" "set_destination" "selected" "$SNAP_MODE"

log "Phase: planner | Action: set_destination | Target: to | Result: done"

# -------------------------
# Datetime (optional)
# -------------------------

if ui_wait_desc_any "Phase: datetime | Action: wait | Target: datetime button | Result: visible" "Time field." "$WAIT_LONG"; then
  :
else
  rc=$?
  warn "Phase: datetime | Action: wait | Target: datetime button | Result: timeout"
  exit $rc
fi

if [[ -n "$DATE_YMD_TRIM" || -n "$TIME_HM_TRIM" ]]; then
  log "Phase: datetime | Action: set | Target: request | Result: requested date=$DATE_YMD_TRIM time=$TIME_HM_TRIM"

  # ---- Open Date/Time menu (CFL) ----
  if ui_has_element "desc:Time field" contains; then
    log "Phase: datetime | Action: tap | Target: time_field | Result: requested"

    if ui_tap_any "open datetime menu" "desc:Time field"; then
      :
    else
      rc=$?
      warn "Phase: datetime | Action: tap | Target: time_field | Result: failed"
      exit $rc
    fi

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

    if ui_tap_any "open date picker" "desc:Date,"; then
      :
    else
      rc=$?
      warn "Phase: datetime | Action: tap | Target: date_picker | Result: failed"
      exit $rc
    fi

    if ui_wait_desc_any \
      "Phase: datetime | Action: wait | Target: calendar | Result: visible" \
      "Previous month" "$WAIT_LONG"; then

      if ui_calendar_set_date_ymd "$DATE_YMD_TRIM"; then
        :
      else
        rc=$?
        warn "Phase: datetime | Action: set | Target: date | Result: failed"
        exit $rc
      fi
      snap "datetime" "validate_date" "validate_date" "$SNAP_MODE"
      log "Phase: datetime | Action: validate | Target: date | Result: ok"

      start=$(date +%s)
      
      while true; do
        ui_refresh
      
        if ui_has_element "resid:android:id/day_picker_view_pager"; then
          log "Phase: datetime | Action: tap | Target: date_ok | Result: calendar_visible"
      
          if ui_tap_any "date ok" "text:OK"; then
            :
          else
            rc=$?
            warn "Phase: datetime | Action: tap | Target: date_ok | Result: failed"
            exit $rc
          fi
      
          sleep_s 0.5
        else
          log "Phase: datetime | Action: wait | Target: calendar | Result: closed"
          break
        fi
      
        (( $(date +%s) - start >= 10 )) && {
          warn "Phase: datetime | Action: wait | Target: calendar | Result: timeout"
          exit 1
        }
      done

      # Retour menu CFL
      if ui_wait_desc_any \
        "Phase: datetime | Action: wait | Target: datetime_menu | Result: back_visible" \
        "Date," "Time," "$WAIT_LONG"; then
        :
      else
        rc=$?
        warn "Phase: datetime | Action: wait | Target: datetime_menu | Result: timeout"
        exit $rc
      fi
    else
      warn "Phase: datetime | Action: set | Target: date | Result: calendar_not_visible"
    fi
  fi

  # ---------------------------------------------------------------------------
  # TIME
  # ---------------------------------------------------------------------------
  if [[ -n "$TIME_HM_TRIM" ]]; then
    log "Phase: datetime | Action: set | Target: time | Result: requested value=$TIME_HM_TRIM"

    if ui_tap_any "open time picker" "desc:Time,"; then
      :
    else
      rc=$?
      warn "Phase: datetime | Action: tap | Target: time_picker_open | Result: failed"
      exit $rc
    fi

    if ui_wait_resid \
      "Phase: datetime | Action: wait | Target: time_picker | Result: visible" \
      "android:id/radial_picker" "$WAIT_LONG"; then

      # Passer en mode texte
      if ui_tap_any "switch to text mode" "resid:android:id/toggle_mode"; then
        :
      else
        rc=$?
        warn "Phase: datetime | Action: tap | Target: toggle_mode | Result: failed"
        exit $rc
      fi

      if ui_wait_element_has_text \
        "Phase: datetime | Action: wait | Target: time_input | Result: text_mode" \
        "resid::id/top_label" "Type in time" "$WAIT_LONG"; then
        :
      else
        rc=$?
        warn "Phase: datetime | Action: wait | Target: time_input | Result: timeout"
        exit $rc
      fi

      if ui_datetime_set_time_12h_text "$TIME_HM_TRIM"; then
        :
      else
        rc=$?
        warn "Phase: datetime | Action: set | Target: time | Result: failed"
        exit $rc
      fi

      log "Phase: datetime | Action: validate | Target: time | Result: ok"

      TIME_PICKER_IDS=(
        "resid:android:id/input_hour"
        "resid:android:id/input_separator"
        "resid:android:id/input_minute"
        "resid:android:id/label_hour"
        "resid:android:id/label_minute"
        "resid:android:id/am_pm_spinner"
        "resid:android:id/time_header"
      )

      start=$(date +%s)

      while true; do
        ui_refresh
      
        picker_visible=0
        for sel in "${TIME_PICKER_IDS[@]}"; do
          if ui_has_element "$sel"; then
            picker_visible=1
            break
          fi
        done
      
        if (( picker_visible )); then
          log "Phase: datetime | Action: tap | Target: time_ok | Result: picker_visible"
      
          if ui_tap_any "time ok" "text:OK"; then
            :
          else
            rc=$?
            warn "Phase: datetime | Action: tap | Target: time_ok | Result: failed"
            exit $rc
          fi
      
          sleep_s 0.5
        else
          log "Phase: datetime | Action: wait | Target: time_picker | Result: closed"
          break
        fi
      
        (( $(date +%s) - start >= 10 )) && {
          warn "Phase: datetime | Action: wait | Target: time_picker | Result: timeout"
          exit 1
        }
      done

      # Retour menu CFL
      if ui_wait_desc_any \
        "Phase: datetime | Action: wait | Target: datetime_menu | Result: back_visible" \
        "Date," "Time," "$WAIT_LONG"; then
        :
      else
        rc=$?
        warn "Phase: datetime | Action: wait | Target: datetime_menu | Result: timeout"
        exit $rc
      fi
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

    if ui_tap_any "apply" "desc:Apply"; then
      :
    else
      rc=$?
      warn "Phase: datetime | Action: apply | Target: cfl | Result: failed"
      exit $rc
    fi
  else
    warn "Phase: datetime | Action: apply | Target: cfl | Result: missing_back_fallback"

    if _ui_key 4; then
      :
    else
      log "Phase: datetime | Action: key | Target: back | Result: skipped"
    fi
  fi
fi

# -------------------------
# Search
# -------------------------

if ui_wait_desc_any "Phase: launch | Action: wait | Target: toolbar buttons | Result: visible" "Start search" "$WAIT_LONG"; then
  :
else
  rc=$?
  warn "Phase: launch | Action: wait | Target: toolbar buttons | Result: timeout"
  exit $rc
fi

if ui_tap_any "select from field" "desc:Start search"; then
  :
else
  rc=$?
  warn "Phase: launch | Action: tap | Target: start_search | Result: failed"
  exit $rc
fi

snap_here "results" "search" "after" 3

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
# Drill all visible connections
# -------------------------

log "Phase: results | Action: search | Target: request | Result: started"

ui_wait_resid "Phase: results | Action: wait | Target: trip-search-result | Result: visible" "trip-search-result" "$WAIT_LONG"

log "Phase: results | Action: drill_connections | Target: trip-search-result | Result: begin"

declare -A SEEN_CONNECTIONS

scrolls=0
final_pass=0

while true; do
  ui_refresh
  mapfile -t ITEMS < <(ui_list_clickable_results_by_changes)
  log "Phase: results | Action: debug_items | Target: trip-search-result | Result: count=${#ITEMS[@]}"

  for i in "${!ITEMS[@]}"; do
    log "Phase: results | Action: debug_item | Target: trip-search-result | Result: index=$i item=$(printf '%q' "${ITEMS[$i]}")"
  done

  new=0

  for item in "${ITEMS[@]}"; do
    IFS=$'\t' read -r desc bounds <<<"$item"
    # Fallback safety: content-desc preferred, bounds as last resort
    raw_key="${desc:-$bounds}"
    key="$(hash_key "$raw_key")"

    [[ -n "${SEEN_CONNECTIONS[$key]:-}" ]] && continue

    # ---- compute tap coords ----
    [[ "$bounds" =~ \[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\] ]] || continue
    cx=$(( (BASH_REMATCH[1] + BASH_REMATCH[3]) / 2 ))
    cy=$(( (BASH_REMATCH[2] + BASH_REMATCH[4]) / 2 ))

    log "Phase: results | Action: open_connection | Target: trip-search-result | Result: tap"
    ui_tap_xy "connection" "$cx" "$cy"

    if ! ui_wait_desc_any "Phase: results | Action: wait | Target: trip_details | Result: visible" "Trip details page" "$WAIT_LONG"
    then
      warn "Phase: results | Action: open_connection | Target: trip_details | Result: not_opened_retry"
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
      mapfile -t ROUTES < <(ui_list_clickable_desc_bounds)
      rnew=0

      for r in "${ROUTES[@]}"; do
        IFS=$'\t' read -r desc rbounds <<<"$r"
        [[ "$desc" != Route\ details* ]] && continue

        raw_rkey="$desc"
        rkey="$(hash_key "$raw_rkey")"

        [[ -n "${SEEN_ROUTES[$rkey]:-}" ]] && continue

        [[ "$rbounds" =~ \[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\] ]] || continue
        rcx=$(( (BASH_REMATCH[1] + BASH_REMATCH[3]) / 2 ))
        rcy=$(( (BASH_REMATCH[2] + BASH_REMATCH[4]) / 2 ))

        log "Phase: results | Action: open_route | Target: route_list | Result: tap text=$desc"
        ui_tap_xy "route" "$rcx" "$rcy"

        if ! ui_wait_desc_any "Phase: results | Action: wait | Target: route_details | Result: visible" "details page" "$WAIT_LONG"; then
          warn "Phase: results | Action: open_route | Target: route_details | Result: not_opened_retry"
          continue
        fi

        SEEN_ROUTES["$rkey"]=1
        rnew=1

        ui_scrollshot_free "route_${rkey}"
        log "Phase: results | Action: scrollshot | Target: route | Result: captured name=route_${rkey}"
        sleep_s 0.3

        _ui_key 4 || true
        ui_wait_desc_any "Phase: results | Action: wait | Target: trip_details | Result: visible" "Trip details page"
        
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
    ui_wait_resid "Phase: results | Action: wait | Target: trip-search-result | Result: visible" "trip-search-result" "$WAIT_LONG"
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
