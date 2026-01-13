#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Snapshot helpers
# SNAP_MODE: 0=off, 1=png only, 2=xml only, 3=png+xml
SNAP_MODE="${SNAP_MODE:-3}"
SNAP_DIR="${SNAP_DIR:-}"   # set by snap_init
SERIAL="${ANDROID_SERIAL:-127.0.0.1:37099}"

log(){ printf '[*] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }

snap_ts() {
  date +"%Y%m%d_%H%M%S_%3N"
}

safe_tag(){ printf '%s' "$1" | tr ' /' '__' | tr -cd 'A-Za-z0-9._-'; }

snap_init(){
  local name="${1:-run}"
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"

  SNAP_DIR="${CFL_RUNS_DIR:-/sdcard/cfl_watch/runs}/${ts}_$(safe_tag "$name")"
  PNG_DIR="$SNAP_DIR/png"
  XML_DIR="$SNAP_DIR/xml"

  mkdir -p "$PNG_DIR" "$XML_DIR"

  log "SNAP_DIR=$SNAP_DIR"
  export SNAP_DIR PNG_DIR XML_DIR
}

_snap_do(){
  local base="$1"   # base = filename sans extension
  local mode="$2"

  case "$mode" in
    0) return 0 ;;

    1)
      adb -s "$SERIAL" shell "
        screencap -p '${PNG_DIR}/${base}.png' >/dev/null 2>&1 || exit 10
        test -s '${PNG_DIR}/${base}.png' || exit 11
      " >/dev/null 2>&1 || warn "png failed: ${base}"
      ;;

    2)
      adb -s "$SERIAL" shell "
        uiautomator dump --compressed '${XML_DIR}/${base}.xml' >/dev/null 2>&1 || exit 20
        test -s '${XML_DIR}/${base}.xml' || exit 21
      " >/dev/null 2>&1 || warn "xml failed: ${base}"
      ;;

    3)
      adb -s "$SERIAL" shell "
        uiautomator dump --compressed '${XML_DIR}/${base}.xml' >/dev/null 2>&1 || exit 30
        test -s '${XML_DIR}/${base}.xml' || exit 31
      " >/dev/null 2>&1 || warn "xml failed: ${base}"

      adb -s "$SERIAL" shell "
        screencap -p '${PNG_DIR}/${base}.png' >/dev/null 2>&1 || exit 40
        test -s '${PNG_DIR}/${base}.png' || exit 41
      " >/dev/null 2>&1 || warn "png failed: ${base}"
      ;;
  esac
}

# snap_from_dump "tag" "/path/to/dump.xml" [mode_override]
# - si mode inclut XML: on COPIE le dump fourni (0 coût uiautomator)
# - si mode inclut PNG: on fait screencap (coût normal)
snap_from_dump(){
  local tag="${1:-snap}"
  local dump_xml="${2:-}"
  local mode="${3:-$SNAP_MODE}"

  mkdir -p "$PNG_DIR" "$XML_DIR"

  local base
  base="$(snap_ts)__$(safe_tag "$tag")"

  case "$mode" in
    2|3)
      if [ -n "$dump_xml" ] && [ -s "$dump_xml" ]; then
        cp -f "$dump_xml" "$XML_DIR/${base}.xml"
      else
        adb -s "$SERIAL" shell uiautomator dump --compressed "$XML_DIR/${base}.xml" >/dev/null 2>&1 || warn "dump failed"
      fi
      ;;
  esac

  [[ "$mode" == 1 || "$mode" == 3 ]] && \
    adb -s "$SERIAL" shell screencap -p "$PNG_DIR/${base}.png" >/dev/null 2>&1 || warn "png failed"

  log "snap_from_dump: $base (mode=$mode)"
}

# snap "tag" [mode_override]
snap(){
  local tag="${1:-snap}"
  local mode="${2:-$SNAP_MODE}"

  mkdir -p "$PNG_DIR" "$XML_DIR"

  local base
  base="$(snap_ts)__$(safe_tag "$tag")"

  _snap_do "$base" "$mode"
  log "snap: $base (mode=$mode)"
}


snap_png(){ snap "${1:-snap}" 1; }
snap_xml(){ snap "${1:-snap}" 2; }
