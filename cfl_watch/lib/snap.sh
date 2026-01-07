#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Snapshot helpers
# SNAP_MODE: 0=off, 1=png only, 2=xml only, 3=png+xml
SNAP_MODE="${SNAP_MODE:-3}"
SNAP_DIR="${SNAP_DIR:-}"   # set by snap_init
SERIAL="${ANDROID_SERIAL:-127.0.0.1:37099}"

log(){ printf '[*] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }

safe_tag(){ printf '%s' "$1" | tr ' /' '__' | tr -cd 'A-Za-z0-9._-'; }

snap_init(){
  local name="${1:-run}"
  local ts
  ts="$(date +%Y-%m-%d_%H-%M-%S)"
  SNAP_DIR="${CFL_RUNS_DIR:-/sdcard/cfl_watch/runs}/${ts}_$(safe_tag "$name")"
  mkdir -p "$SNAP_DIR"
  log "SNAP_DIR=$SNAP_DIR (SNAP_MODE=$SNAP_MODE)"
  export SNAP_DIR
}

_snap_do(){
  local base="$1"
  local mode="$2"

  case "$mode" in
    0) return 0 ;;

    1)
      adb -s "$SERIAL" shell "
        screencap -p '${base}.png' >/dev/null 2>&1 || exit 10
        test -s '${base}.png' || exit 11
      " >/dev/null 2>&1 || warn "png missing/empty or screencap failed: ${base}.png"
      ;;

    2)
      adb -s "$SERIAL" shell "
        uiautomator dump --compressed '${base}.xml' >/dev/null 2>&1 || exit 20
        test -s '${base}.xml' || exit 21
      " >/dev/null 2>&1 || warn "xml missing/empty or dump failed: ${base}.xml"
      ;;

    3)
      # 1) xml + check (1 seul adb)
      adb -s "$SERIAL" shell "
        uiautomator dump --compressed '${base}.xml' >/dev/null 2>&1 || exit 30
        test -s '${base}.xml' || exit 31
      " >/dev/null 2>&1 || warn "xml missing/empty or dump failed: ${base}.xml"

      # 2) png + check (1 seul adb)
      adb -s "$SERIAL" shell "
        screencap -p '${base}.png' >/dev/null 2>&1 || exit 40
        test -s '${base}.png' || exit 41
      " >/dev/null 2>&1 || warn "png missing/empty or screencap failed: ${base}.png"
      ;;

    *)
      warn "SNAP_MODE invalide: $mode (0/1/2/3 attendu)"
      return 1
      ;;
  esac
}

# snap "tag" [mode_override]
snap(){
  local tag="${1:-snap}"
  local mode="${2:-$SNAP_MODE}"

  if [ -z "$SNAP_DIR" ]; then
    SNAP_DIR="${CFL_RUNS_DIR:-/sdcard/cfl_watch/runs}/$(date +%Y-%m-%d_%H-%M-%S)_run"
  fi
  mkdir -p "$SNAP_DIR"

  local ts base
  ts="$(date +%H-%M-%S)"
  base="$SNAP_DIR/${ts}_$(safe_tag "$tag")"

  _snap_do "$base" "$mode"
  log "snap: ${ts}_${tag} (mode=$mode)"
}

snap_png(){ snap "${1:-snap}" 1; }
snap_xml(){ snap "${1:-snap}" 2; }
