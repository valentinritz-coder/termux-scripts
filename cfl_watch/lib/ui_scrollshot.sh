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
  # ui_scrollshot_region "tag" ":id/journey_details_head"
  local tag="$1"
  local anchor_resid="$2"

  [[ -n "${SNAP_DIR:-}" ]] || { warn "SNAP_DIR not set"; return 1; }

  ui_refresh
  local top_y
  top_y="$(ui_get_resid_top_y "$anchor_resid")"

  if [[ -z "$top_y" ]]; then
    warn "scrollshot: anchor not found: $anchor_resid"
    return 1
  fi

  local ts dir
  ts="$(date +%H-%M-%S)"
  dir="$SNAP_DIR/${ts}_${tag}_scrollshot"
  mkdir -p "$dir"

  log "scrollshot: anchor=$anchor_resid top_y=$top_y dir=$dir"

  local w h
  read -r w h < <(ui_screen_size)

  local x=$(( w / 2 ))
  local y_start=$(( h - SCROLLSHOT_BOTTOM_MARGIN - 20 ))
  local y_end=$(( top_y + 40 ))

  log "scrollshot: swipe x=$x y_start=$y_start y_end=$y_end"

  local prev_hash=""
  local streak=0

  for ((i=0; i<=SCROLLSHOT_MAX_SCROLL; i++)); do
    local png="$dir/$(printf '%03d' "$i").png"
    ui_screencap_png "$png"

    local hsh
    hsh="$(ui_hash_png "$png")"

    if [[ -n "$prev_hash" && "$hsh" == "$prev_hash" ]]; then
      streak=$((streak+1))
      log "scrollshot: identical streak=$streak at i=$i"
      if (( streak >= SCROLLSHOT_STOP_STREAK && i >= 2 )); then
        rm -f "$png"
        log "scrollshot: stop (no more scroll)"
        break
      fi
    else
      streak=0
    fi

    prev_hash="$hsh"

    adb -s "$(_ui_serial)" shell input swipe "$x" "$y_start" "$x" "$y_end" "$SCROLLSHOT_SWIPE_MS"
    sleep_s "$SCROLLSHOT_SETTLE"
  done

  log "scrollshot: done -> $dir"
  printf '%s\n' "$dir"
}
