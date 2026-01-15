#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# --------------------------------------------------
# ui_scrollshot.sh (CFL WATCH)
#
# Objectif:
# - Capturer une zone scrollable à partir d’un anchor resid
# - Sauver une série de PNG: 000.png, 001.png, ...
# - STOP quand l’image ne change plus
#
# AUCUN stitch ici.
# AUCUN python.
# --------------------------------------------------

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
# UI libs
. "$CFL_CODE_DIR/lib/ui_api.sh"

: "${SCROLLSHOT_MAX_SCROLL:=25}"
: "${SCROLLSHOT_SETTLE:=0.5}"
: "${SCROLLSHOT_SWIPE_MS:=300}"
: "${SCROLLSHOT_STOP_STREAK:=1}"
: "${SCROLLSHOT_BOTTOM_MARGIN:=160}"   # navbar Android

# --------------------------------------------------

_ui_serial() {
  printf '%s' "${SERIAL:-${ANDROID_SERIAL:-127.0.0.1:37099}}"
}

ui_screencap_png() {
  local out="$1"
  adb -s "$(_ui_serial)" exec-out screencap -p > "$out"
}

ui_screen_size() {
  adb -s "$(_ui_serial)" shell wm size | tr -d '\r' | \
    awk '/Physical size:/ {split($3,a,"x"); print a[1],a[2]}'
}

ui_hash_png() {
  sha1sum "$1" | awk '{print $1}'
}

ui_get_resid_top_y() {
  # Retourne le Y le plus haut pour un resid
  local resid="$1"

  [[ -n "${UI_DUMP_CACHE:-}" && -s "${UI_DUMP_CACHE:-}" ]] || ui_refresh

  if [[ "$resid" == :id/* ]]; then
    resid="${APP_PACKAGE:-de.hafas.android.cfl}${resid}"
  fi

  python - "$UI_DUMP_CACHE" "$resid" <<'PY'
import sys, re, xml.etree.ElementTree as ET
dump, resid = sys.argv[1], sys.argv[2]
root = ET.parse(dump).getroot()
rb = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")
ys = []
for n in root.iter("node"):
    if n.get("resource-id") == resid:
        m = rb.match(n.get("bounds",""))
        if m:
            ys.append(int(m.group(2)))
print(min(ys) if ys else "", end="")
PY
}

ui_scrollshot_region() {
  # Usage:
  # ui_scrollshot_region "route_abcd1234" ":id/journey_details_head"
  local tag="$1"
  local anchor_resid="$2"

  [[ -n "${PNG_DIR:-}" && -n "${XML_DIR:-}" ]] || {
    warn "scrollshot: PNG_DIR / XML_DIR not set"
    return 1
  }

  ui_refresh

  local top_y
  top_y="$(ui_get_resid_top_y "$anchor_resid")"

  if [[ -z "$top_y" ]]; then
    warn "scrollshot: anchor not found: $anchor_resid"
    return 1
  fi

  # 🔒 timestamp canonique UNIQUE pour toute la séquence
  local ts
  ts="$(date +"%Y%m%d_%H%M%S_%3N")"

  log "scrollshot: tag=$tag anchor=$anchor_resid top_y=$top_y ts=$ts"

  local prev_hash=""
  local streak=0
  local i=1

  for ((n=0; n<=SCROLLSHOT_MAX_SCROLL; n++)); do
    printf -v sfx "__S%02d" "$i"

    local png="$PNG_DIR/${ts}__${tag}${sfx}.png"
    local xml="$XML_DIR/${ts}__${tag}${sfx}.xml"

    ui_screencap_png "$png"
    ui_refresh
    cp -f "$UI_DUMP_CACHE" "$xml"

    local hsh
    hsh="$(ui_hash_png "$png")"

    if [[ -n "$prev_hash" && "$hsh" == "$prev_hash" ]]; then
      streak=$((streak + 1))
      log "scrollshot: identical streak=$streak at S$(printf '%02d' "$i")"

      if (( streak >= SCROLLSHOT_STOP_STREAK && i >= 2 )); then
        rm -f "$png" "$xml"
        log "scrollshot: stop (no more scroll)"
        break
      fi
    else
      streak=0
    fi

    prev_hash="$hsh"
    i=$((i + 1))

    ui_scroll_down_soft
    sleep_s "$SCROLLSHOT_SETTLE"

  done

  log "scrollshot: done (${i}-1 frames)"
}

ui_scrollshot_free() {
  # Usage:
  # ui_scrollshot_free "route_abcd1234"
  local tag="$1"

  [[ -n "${PNG_DIR:-}" && -n "${XML_DIR:-}" ]] || {
    warn "scrollshot_free: PNG_DIR / XML_DIR not set"
    return 1
  }

  ui_refresh

  # 🔒 timestamp canonique UNIQUE pour toute la séquence
  local ts
  ts="$(date +"%Y%m%d_%H%M%S_%3N")"

  log "scrollshot_free: tag=$tag ts=$ts"

  local prev_hash=""
  local streak=0
  local i=1

  for ((n=0; n<=SCROLLSHOT_MAX_SCROLL; n++)); do
    printf -v sfx "__S%02d" "$i"

    local png="$PNG_DIR/${ts}__${tag}${sfx}.png"
    local xml="$XML_DIR/${ts}__${tag}${sfx}.xml"

    ui_screencap_png "$png"
    ui_refresh
    cp -f "$UI_DUMP_CACHE" "$xml"

    local hsh
    hsh="$(ui_hash_png "$png")"

    if [[ -n "$prev_hash" && "$hsh" == "$prev_hash" ]]; then
      streak=$((streak + 1))
      log "scrollshot_free: identical streak=$streak at S$(printf '%02d' "$i")"

      if (( streak >= SCROLLSHOT_STOP_STREAK && i >= 2 )); then
        rm -f "$png" "$xml"
        log "scrollshot_free: stop (no more scroll)"
        break
      fi
    else
      streak=0
    fi

    prev_hash="$hsh"
    i=$((i + 1))

    ui_scroll_down_soft
    sleep_s "$SCROLLSHOT_SETTLE"
  done

  log "scrollshot_free: done ($((i-1)) frames)"
}


