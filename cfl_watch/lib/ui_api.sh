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

ui_scroll_down() {
  # Scroll vertical standard, stable sur 99% des écrans
  maybe adb shell input swipe 540 1600 540 600 300
}

hash_key() {
  printf '%s' "$1" | sha1sum | awk '{print $1}'
}

# -------------------------
# Wait helpers (readable)
# -------------------------

_ui_match_regex() {
  local sel="$1"
  local mode="$2"

  case "$sel" in
    resid:*)
      # resid = toujours regex contains
      resid_regex "${sel#resid:}"
      ;;

    desc:*)
      local v
      v="$(regex_escape_ere "${sel#desc:}")"
      case "$mode" in
        exact)    echo "content-desc=\"$v\"" ;;
        contains) echo "content-desc=\"[^\"]*$v[^\"]*\"" ;;
        *) return 2 ;;
      esac
      ;;

    text:*)
      local v
      v="$(regex_escape_ere "${sel#text:}")"
      case "$mode" in
        exact)    echo "text=\"$v\"" ;;
        contains) echo "text=\"[^\"]*$v[^\"]*\"" ;;
        *) return 2 ;;
      esac
      ;;

    *)
      return 2
      ;;
  esac
}

ui_wait_resid(){
  local label="$1"
  local resid="$2"
  local timeout="${3:-$WAIT_LONG}"
  UI_DUMP_CACHE="$(wait_dump_grep "$(resid_regex "$resid")" "$timeout" "$WAIT_POLL" || dump_ui)"
  log "wait ok: $label"
}

ui_wait_desc_any() {
  # Usage:
  #   ui_wait_desc_any "label" "Select start"
  #   ui_wait_desc_any "label" "Select start" 10
  #   ui_wait_desc_any "label" "destination" "arrivée" 15

  local label="$1"
  shift

  local timeout="$WAIT_LONG"

  # Si le dernier argument est un nombre → timeout
  if [[ "${@: -1}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    timeout="${@: -1}"
    set -- "${@:1:$(($#-1))}"
  fi

  local parts=()
  local n
  for n in "$@"; do
    n="$(regex_escape_ere "$n")"
    parts+=( "$n" )
  done

  local joined
  joined="$(IFS='|'; printf '%s' "${parts[*]}")"

  UI_DUMP_CACHE="$(
    wait_dump_grep \
      "content-desc=\"[^\"]*(${joined})[^\"]*\"" \
      "$timeout" \
      "$WAIT_POLL" \
    || dump_ui
  )"

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

ui_tap_xy() {
  # Usage:
  #   ui_tap_xy "label" x y

  local label="$1"
  local x="$2"
  local y="$3"

  if [[ -z "$x" || -z "$y" ]]; then
    warn "ui_tap_xy: coordonnées invalides ($x,$y)"
    return 1
  fi

  log "Tap $label at $x,$y"
  maybe tap "$x" "$y"
  return 0
}

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

ui_snap(){
  # ui_snap "tag" [mode]
  local tag="${1:-snap}"
  local mode="${2:-${SNAP_MODE:-3}}"

  [[ -n "${PNG_DIR:-}" && -n "${XML_DIR:-}" ]] || {
    warn "ui_snap: PNG_DIR / XML_DIR non définis (snap_init manquant ?)"
    return 1
  }

  local base
  base="$(date +"%Y%m%d_%H%M%S_%3N")__$(safe_tag "$tag")"

  case "$mode" in
    0) return 0 ;;

    1)
      adb -s "${SERIAL:-${ANDROID_SERIAL:-127.0.0.1:37099}}" \
        shell screencap -p "$PNG_DIR/${base}.png" >/dev/null 2>&1 \
        || warn "ui_snap: screencap failed"
      ;;

    2)
      if [[ -n "${UI_DUMP_CACHE:-}" && -s "$UI_DUMP_CACHE" ]]; then
        cp -f "$UI_DUMP_CACHE" "$XML_DIR/${base}.xml" \
          || warn "ui_snap: copy xml failed"
      else
        warn "ui_snap: pas de cache xml (ui_refresh manquant)"
      fi
      ;;

    3)
      if [[ -n "${UI_DUMP_CACHE:-}" && -s "$UI_DUMP_CACHE" ]]; then
        cp -f "$UI_DUMP_CACHE" "$XML_DIR/${base}.xml" \
          || warn "ui_snap: copy xml failed"
      else
        warn "ui_snap: pas de cache xml (ui_refresh manquant)"
      fi

      adb -s "${SERIAL:-${ANDROID_SERIAL:-127.0.0.1:37099}}" \
        shell screencap -p "$PNG_DIR/${base}.png" >/dev/null 2>&1 \
        || warn "ui_snap: screencap failed"
      ;;
    *)
      warn "ui_snap: mode invalide: $mode"
      return 1
      ;;
  esac

  log "snap: $base (mode=$mode)"
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

ui_has_element() {
  # Vérifie si un élément existe DANS LE CACHE ACTUEL
  #
  # Usage:
  #   ui_has_element "resid:$ID_DATETIME"
  #   ui_has_element "desc:Show navigation drawer"
  #   ui_has_element "desc:Tab layout_itineraries_accessibility_label" contains
  #
  [[ -n "${UI_DUMP_CACHE:-}" && -s "$UI_DUMP_CACHE" ]] || ui_refresh

  local sel="$1"
  local mode="${2:-exact}"   # exact | contains

  case "$sel" in
    resid:*)
      # resid est déjà en regex → toujours contains
      grep -Eq "$(resid_regex "${sel#resid:}")" "$UI_DUMP_CACHE"
      ;;

    desc:*)
      case "$mode" in
        exact)
          grep -Fq "content-desc=\"${sel#desc:}\"" "$UI_DUMP_CACHE"
          ;;
        contains)
          grep -Fq "content-desc=\"" "$UI_DUMP_CACHE" \
            && grep -Fq "${sel#desc:}" "$UI_DUMP_CACHE"
          ;;
        *)
          warn "ui_has_element: invalid match mode ($mode)"
          return 2
          ;;
      esac
      ;;

    text:*)
      case "$mode" in
        exact)
          grep -Fq "text=\"${sel#text:}\"" "$UI_DUMP_CACHE"
          ;;
        contains)
          grep -Fq "text=\"" "$UI_DUMP_CACHE" \
            && grep -Fq "${sel#text:}" "$UI_DUMP_CACHE"
          ;;
        *)
          warn "ui_has_element: invalid match mode ($mode)"
          return 2
          ;;
      esac
      ;;

    *)
      warn "ui_has_element: sélecteur inconnu ($sel)"
      return 2
      ;;
  esac
}


ui_wait_element_has_text() {
  local label="$1"
  local sel="$2"
  local text="$3"
  local timeout="${4:-$WAIT_LONG}"

  local start now
  start=$(date +%s)

  while true; do
    ui_refresh
    if ui_element_has_text "$sel" "$text"; then
      log "wait ok: $label"
      return 0
    fi

    now=$(date +%s)
    if (( now - start >= timeout )); then
      warn "wait timeout: $label"
      return 1
    fi

    sleep_s "${WAIT_POLL:-0.5}"
  done
}

ui_tap_child_of_resid() {
  # Usage:
  #   ui_tap_child_of_resid "label" ":id/request_screen_container" 0

  local label="$1"
  local resid="$2"
  local index="$3"

  [[ -n "${UI_DUMP_CACHE:-}" && -s "$UI_DUMP_CACHE" ]] || ui_refresh

  # Normaliser :id/foo
  if [[ "$resid" == :id/* ]]; then
    resid="${APP_PACKAGE:-de.hafas.android.cfl}${resid}"
  fi

  local coords
  coords="$(
    python - "$UI_DUMP_CACHE" "$resid" "$index" <<'PY'
import sys, re, xml.etree.ElementTree as ET

dump, resid, index = sys.argv[1], sys.argv[2], sys.argv[3]

_bounds = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")

def center(b):
    m = _bounds.match(b or "")
    if not m:
        return None
    x1,y1,x2,y2 = map(int, m.groups())
    return (x1+x2)//2, (y1+y2)//2

root = ET.parse(dump).getroot()

for node in root.iter("node"):
    if node.get("resource-id") != resid:
        continue

    # enfant direct seulement
    for child in node:
        if child.get("index") == index and child.get("clickable") == "true":
            c = center(child.get("bounds"))
            if c:
                print(f"{c[0]} {c[1]}")
                sys.exit(0)

sys.exit(1)
PY
  )"

  if [[ -z "${coords// }" ]]; then
    warn "Child index=$index not found in $resid"
    return 1
  fi

  local x y
  read -r x y <<<"$coords"

  log "Tap $label at $x,$y"
  maybe tap "$x" "$y"
}

ui_list_resid_bounds() {
  # Usage:
  #   ui_list_resid_bounds ":id/haf_connection_view"

  local resid="$1"

  [[ -n "${UI_DUMP_CACHE:-}" && -s "$UI_DUMP_CACHE" ]] || ui_refresh

  # Normaliser :id/foo
  if [[ "$resid" == :id/* ]]; then
    resid="${APP_PACKAGE:-de.hafas.android.cfl}${resid}"
  fi

  python - "$UI_DUMP_CACHE" "$resid" <<'PY'
import sys, re, xml.etree.ElementTree as ET

dump, resid = sys.argv[1], sys.argv[2]

_bounds = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")

def bounds(b):
    m = _bounds.match(b or "")
    if not m:
        return None
    return m.groups()

root = ET.parse(dump).getroot()

for node in root.iter("node"):
    if node.get("resource-id") != resid:
        continue

    b = bounds(node.get("bounds"))
    if not b:
        continue

    print(" ".join(b))
PY
}

ui_collect_all_resid_bounds() {
  local resid="$1"
  local max_scroll="${2:-15}"

  local ALL=()
  local scrolls=0

  log "Collect all for $resid (max_scroll=$max_scroll)" >&2

  while true; do
    ui_refresh

    mapfile -t VISIBLE < <(ui_list_resid_bounds "$resid" || true)

    log "Visible count: ${#VISIBLE[@]}" >&2

    local new=0
    for line in "${VISIBLE[@]}"; do
      if [[ ! " ${ALL[*]} " =~ " $line " ]]; then
        ALL+=("$line")
        new=1
      fi
    done

    log "Total collected so far: ${#ALL[@]}" >&2

    [[ $new -eq 0 ]] && break

    scrolls=$((scrolls + 1))
    [[ $scrolls -ge $max_scroll ]] && break

    ui_scroll_down
    sleep_s 0.4
  done

  # DONNÉES UNIQUEMENT
  printf '%s\n' "${ALL[@]}"
}

ui_list_resid_desc_bounds() {
  local resid="$1"

  [[ -n "${UI_DUMP_CACHE:-}" && -s "$UI_DUMP_CACHE" ]] || ui_refresh

  if [[ "$resid" == :id/* ]]; then
    resid="${APP_PACKAGE:-de.hafas.android.cfl}${resid}"
  fi

  python - "$UI_DUMP_CACHE" "$resid" <<'PY'
import sys, re, xml.etree.ElementTree as ET

dump, resid = sys.argv[1], sys.argv[2]
root = ET.parse(dump).getroot()

re_nl = re.compile(r"[\r\n]+")
re_ws = re.compile(r"[ \t]+")

for n in root.iter("node"):
    if n.get("resource-id") != resid:
        continue

    desc = (n.get("content-desc") or "")
    bounds = n.get("bounds") or ""

    # ElementTree convertit &#10; -> '\n' : on remet tout sur UNE ligne
    desc = re_nl.sub(" | ", desc)     # ou " " si tu veux
    desc = desc.replace("\t", " ")    # protège le séparateur '\t' de ton output
    desc = re_ws.sub(" ", desc).strip()

    if not desc or not bounds:
        continue

    print(f"{desc}\t{bounds}")
PY
}

ui_list_resid_text_bounds() {
  # Usage: ui_list_resid_text_bounds ":id/foo"
  local resid="$1"

  [[ -n "${UI_DUMP_CACHE:-}" && -s "$UI_DUMP_CACHE" ]] || ui_refresh

  # Normaliser :id/foo -> de.hafas.android.cfl:id/foo
  if [[ "$resid" == :id/* ]]; then
    resid="${APP_PACKAGE:-de.hafas.android.cfl}${resid}"
  fi

  python - "$UI_DUMP_CACHE" "$resid" <<'PY'
import sys, re, xml.etree.ElementTree as ET

dump, resid = sys.argv[1], sys.argv[2]
root = ET.parse(dump).getroot()

re_nl = re.compile(r"[\r\n]+")
re_ws = re.compile(r"[ \t]+")

for n in root.iter("node"):
    if n.get("resource-id") != resid:
        continue

    text = n.get("text") or ""
    bounds = n.get("bounds") or ""

    # Protéger la sortie: une ligne par node, tab = séparateur réservé
    text = re_nl.sub(" ", text)      # \r \n -> espace
    text = text.replace("\t", " ")   # ne jamais laisser un tab dans le champ
    text = re_ws.sub(" ", text).strip()

    if not text or not bounds:
        continue

    print(f"{text}\t{bounds}")
PY
}

ui_wait_element_gone() {
  local label="$1"
  local sel="$2"
  local mode="${3:-exact}"
  local timeout="${4:-$WAIT_LONG}"

  local re
  re="$(_ui_match_regex "$sel" "$mode")" || {
    warn "ui_wait_element_gone: invalid selector ($sel)"
    return 2
  }

  local start
  start="$(date +%s)"

  while true; do
    ui_refresh

    if ! grep -Eq "$re" "$UI_DUMP_CACHE"; then
      log "wait gone ok: $label"
      return 0
    fi

    (( $(date +%s) - start >= timeout )) && break
    sleep_s "$WAIT_POLL"
  done

  warn "wait gone timeout: $label"
  return 1
}



