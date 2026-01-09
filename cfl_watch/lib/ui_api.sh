#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Human-friendly UI API.
#
# Depends on:
#   - lib/common.sh: log, warn, maybe, type_text, key, sleep_s
#   - lib/snap.sh:   snap_init, safe_tag, SNAP_DIR, SNAP_MODE, SERIAL
#   - lib/ui_core.sh: dump_ui, wait_dump_grep, wait_results_ready, resid_regex, regex_escape_ere
#   - lib/ui_select.sh: tap_by_selector, tap_first_result
#
# Provides:
#   ui_refresh
#   ui_wait_resid
#   ui_wait_desc_any
#   ui_wait_text_any
#   ui_wait_search_button
#   ui_tap_resid / ui_tap_desc / ui_tap_text
#   ui_tap_any
#   ui_type_and_wait_results
#   ui_pick_suggestion
#   ui_snap / ui_snap_here

: "${WAIT_POLL:=0.0}"
: "${WAIT_SHORT:=20}"
: "${WAIT_LONG:=30}"

UI_DUMP_CACHE=""

ui_refresh(){
  UI_DUMP_CACHE="$(dump_ui)"
}

# -------------------------
# Wait helpers (readable)
# -------------------------

ui_wait_resid(){
  local label="$1"
  local resid="$2"
  local timeout="${3:-$WAIT_LONG}"
  UI_DUMP_CACHE="$(wait_dump_grep "$(resid_regex "$resid")" "$timeout" "$WAIT_POLL" || dump_ui)"
  log "wait ok: $label"
}

ui_wait_desc_any(){
  # ui_wait_desc_any "label" timeout "destination" "arrivée" ...
  local label="$1"
  local timeout="$2"
  shift 2

  local parts=()
  local n
  for n in "$@"; do
    n="$(regex_escape_ere "$n")"
    parts+=( "$n" )
  done

  local joined
  joined="$(IFS='|'; printf '%s' "${parts[*]}")"
  UI_DUMP_CACHE="$(wait_dump_grep "content-desc=\"[^\"]*(${joined})[^\"]*\"" "$timeout" "$WAIT_POLL" || dump_ui)"
  log "wait ok: $label"
}

ui_wait_text_any(){
  # ui_wait_text_any "label" timeout "Rechercher" "Itinéraires" ...
  local label="$1"
  local timeout="$2"
  shift 2

  local parts=()
  local n
  for n in "$@"; do
    n="$(regex_escape_ere "$n")"
    parts+=( "$n" )
  done

  local joined
  joined="$(IFS='|'; printf '%s' "${parts[*]}")"
  UI_DUMP_CACHE="$(wait_dump_grep "text=\"[^\"]*(${joined})[^\"]*\"" "$timeout" "$WAIT_POLL" || dump_ui)"
  log "wait ok: $label"
}

ui_wait_search_button(){
  local timeout="${1:-$WAIT_LONG}"
  UI_DUMP_CACHE="$(wait_dump_grep \
    "$(resid_regex "$ID_BTN_SEARCH_DEFAULT")|$(resid_regex "$ID_BTN_SEARCH")|text=\"Rechercher\"|text=\"Itinéraires\"" \
    "$timeout" "$WAIT_POLL" || dump_ui)"
  log "wait ok: search button"
}

# -------------------------
# Tap helpers (readable)
# -------------------------

ui_tap_resid(){
  local label="$1"; local resid="$2"
  tap_by_selector "$label" "$UI_DUMP_CACHE" "resource-id=$resid"
}

ui_tap_desc(){
  local label="$1"; local needle="$2"
  tap_by_selector "$label" "$UI_DUMP_CACHE" "content-desc=$needle"
}

ui_tap_text(){
  local label="$1"; local needle="$2"
  tap_by_selector "$label" "$UI_DUMP_CACHE" "text=$needle"
}

ui_tap_any(){
  # Usage:
  #   ui_tap_any "start field" \
  #     "resid:$ID_START" \
  #     "desc:Select start" \
  #     "desc:départ" \
  #     "text:Rechercher"
  #
  # Each selector refreshes nothing: call ui_refresh/ui_wait_* before.
  local label="$1"; shift

  local sel
  for sel in "$@"; do
    case "$sel" in
      resid:*)
        ui_tap_resid "$label (id)" "${sel#resid:}" && return 0 || true
        ;;
      desc:*)
        ui_tap_desc "$label (desc)" "${sel#desc:}" && return 0 || true
        ;;
      text:*)
        ui_tap_text "$label (text)" "${sel#text:}" && return 0 || true
        ;;
      first_result:*)
        tap_first_result "$label (first)" "$UI_DUMP_CACHE" && return 0 || true
        ;;
      attr:*)
        # raw attribute match: attr:clickable=true  -> "clickable=true"
        tap_by_selector "$label (attr)" "$UI_DUMP_CACHE" "${sel#attr:}" && return 0 || true
        ;;
      *)
        warn "ui_tap_any: selector inconnu: $sel"
        ;;
    esac
  done

  return 1
}

ui_tap_retry(){
  local label="$1"
  local tries="${2:-3}"
  shift 2

  local i
  for ((i=1;i<=tries;i++)); do
    ui_refresh
    if ui_tap_any "$label" "$@"; then
      return 0
    fi
  done
  return 1
}

# -------------------------
# Typed flows
# -------------------------

ui_type_and_wait_results(){
  local label="$1"
  local value="$2"

  log "Type $label: $value"
  # small settle helps IME overlays
  sleep_s 0.20
  maybe type_text "$value"

  wait_results_ready "$WAIT_LONG" "$WAIT_POLL" || true
  ui_refresh
}

ui_pick_suggestion(){
  local label="$1"
  local value="$2"

  # 1) prefer content-desc contains
  ui_tap_any "$label" \
    "desc:$value" \
    "text:$value" \
    "first_result:" \
  || {
    warn "Suggestion introuvable: $label ($value)"
    return 1
  }
}

# -------------------------
# Fast snapshots using the current dump cache
# -------------------------

_ui_ts(){ date +%H-%M-%S; }

ui_snap(){
  # ui_snap "tag" [mode]
  # mode: 0=off, 1=png, 2=xml(from cache), 3=png+xml(from cache)
  local tag="${1:-snap}"
  local mode="${2:-${SNAP_MODE:-3}}"

  if [ -z "${SNAP_DIR:-}" ]; then
    warn "ui_snap: SNAP_DIR vide (tu as oublié snap_init ?)"
    return 1
  fi

  mkdir -p "$SNAP_DIR" >/dev/null 2>&1 || true

  local ts base
  ts="$(_ui_ts)"
  # safe_tag comes from snap.sh; fallback if not sourced
  if ! command -v safe_tag >/dev/null 2>&1; then
    safe_tag(){ printf '%s' "$1" | tr ' /' '__' | tr -cd 'A-Za-z0-9._-'; }
  fi
  base="$SNAP_DIR/${ts}_$(safe_tag "$tag")"

  case "$mode" in
    0) return 0 ;;
    1)
      adb -s "${SERIAL:-${ANDROID_SERIAL:-127.0.0.1:37099}}" shell screencap -p "${base}.png" >/dev/null 2>&1 \
        || warn "ui_snap: screencap failed"
      ;;
    2)
      if [ -n "${UI_DUMP_CACHE:-}" ] && [ -s "$UI_DUMP_CACHE" ]; then
        cp -f "$UI_DUMP_CACHE" "${base}.xml" >/dev/null 2>&1 || warn "ui_snap: copy xml failed"
      else
        warn "ui_snap: pas de cache xml (appelle ui_refresh avant)"
      fi
      ;;
    3)
      if [ -n "${UI_DUMP_CACHE:-}" ] && [ -s "$UI_DUMP_CACHE" ]; then
        cp -f "$UI_DUMP_CACHE" "${base}.xml" >/dev/null 2>&1 || warn "ui_snap: copy xml failed"
      else
        warn "ui_snap: pas de cache xml (appelle ui_refresh avant)"
      fi
      adb -s "${SERIAL:-${ANDROID_SERIAL:-127.0.0.1:37099}}" shell screencap -p "${base}.png" >/dev/null 2>&1 \
        || warn "ui_snap: screencap failed"
      ;;
    *)
      warn "ui_snap: mode invalide: $mode"
      return 1
      ;;
  esac

  log "snap: ${ts}_${tag} (mode=$mode)"
}

ui_snap_here(){
  local tag="$1"
  local mode="${2:-${SNAP_MODE:-3}}"
  ui_refresh
  ui_snap "$tag" "$mode"
}

ui_element_has_text() {
  # Vérifie si un élément (resid ou desc) a un ENFANT
  # dont le text contient la valeur donnée.
  #
  # Usage:
  #   ui_element_has_text "resid::id/toolbar" "Home"
  #   ui_element_has_text "desc:Show navigation drawer" "drawer"
  #
  local sel="$1"
  local text="$2"

  [[ -n "${UI_DUMP_CACHE:-}" && -s "$UI_DUMP_CACHE" ]] || ui_refresh

  local esc_txt esc_sel block

  esc_txt="$(regex_escape_ere "$text")"

  case "$sel" in
    resid:*)
      esc_sel="$(resid_regex "${sel#resid:}")"
      ;;
    desc:*)
      esc_sel="content-desc=\"[^\"]*$(regex_escape_ere "${sel#desc:}")"
      ;;
    *)
      warn "ui_element_has_text: sélecteur invalide ($sel)"
      return 2
      ;;
  esac

  # Extraire le bloc XML de l'élément + ses enfants
  block="$(grep -n "$esc_sel" "$UI_DUMP_CACHE" | cut -d: -f1 | head -n1)"

  [[ -n "$block" ]] || return 1

  # Lire une fenêtre raisonnable après le node (toolbar peu profond)
  sed -n "$block,$((block+40))p" "$UI_DUMP_CACHE" | grep -Eq "text=\"[^\"]*${esc_txt}[^\"]*\""
}

ui_wait_element_has_text() {
  # Attend qu’un élément (resid ou desc) ait un ENFANT
  # dont le text contient la valeur donnée.
  #
  # Usage:
  #   ui_wait_element_has_text "label" "resid::id/toolbar" "Home" 10
  #   ui_wait_element_has_text "label" "desc:Show navigation drawer" "drawer" 5
  #
  local label="$1"
  local sel="$2"
  local text="$3"
  local timeout="${4:-$WAIT_LONG}"

  local esc_txt esc_sel re

  esc_txt="$(regex_escape_ere "$text")"

  case "$sel" in
    resid:*)
      esc_sel="$(resid_regex "${sel#resid:}")"
      ;;
    desc:*)
      esc_sel="content-desc=\"[^\"]*$(regex_escape_ere "${sel#desc:}")"
      ;;
    *)
      warn "ui_wait_element_has_text: sélecteur invalide ($sel)"
      return 2
      ;;
  esac

  # Regex multi-lignes:
  # - match le node parent
  # - puis dans une fenêtre raisonnable, un text="..."
  #
  # On ne peut PAS faire un regex XML parfait, mais ça suffit
  re="${esc_sel}(.|\n){0,800}?text=\"[^\"]*${esc_txt}[^\"]*\""

  if UI_DUMP_CACHE="$(wait_dump_grep "$re" "$timeout" "$WAIT_POLL")"; then
    log "wait ok: $label"
    return 0
  fi

  UI_DUMP_CACHE="$(dump_ui)"
  warn "wait timeout: $label"
  return 1
}

