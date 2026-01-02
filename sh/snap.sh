#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="${BASE:-/sdcard/cfl_watch}"
SER="${ANDROID_SERIAL:-127.0.0.1:37099}"

mkdir -p "$BASE"/{runs,tmp,logs}

# 0 = off, 1 = png only, 2 = xml only, 3 = png+xml
SNAP_MODE="${SNAP_MODE:-3}"

snap_init() {
  local name="${1:-run}"
  local ts
  ts="$(date +%Y-%m-%d_%H-%M-%S)"
  export SNAP_DIR="$BASE/runs/${ts}_${name}"
  mkdir -p "$SNAP_DIR"
  echo "[*] SNAP_DIR=$SNAP_DIR"
}

_snap_do() {
  local base="$1"
  local mode="$2"

  case "$mode" in
    0) return 0 ;;
    1)
      adb -s "$SER" shell screencap -p "${base}.png" >/dev/null 2>&1 || true
      ;;
    2)
      adb -s "$SER" shell uiautomator dump --compressed "${base}.xml" >/dev/null 2>&1 || true
      ;;
    3)
      adb -s "$SER" shell uiautomator dump --compressed "${base}.xml" >/dev/null 2>&1 || true
      adb -s "$SER" shell screencap -p "${base}.png" >/dev/null 2>&1 || true
      ;;
    *)
      echo "[!] SNAP_MODE invalide: $mode (attendu 0/1/2/3)" >&2
      return 1
      ;;
  esac
}

# snap "tag" [mode_override]
snap() {
  local tag="${1:-snap}"
  local mode="${2:-$SNAP_MODE}"
  local ts base
  ts="$(date +%H-%M-%S)"
  base="$SNAP_DIR/${ts}_${tag}"
  _snap_do "$base" "$mode"
  echo "[*] snap: ${ts}_${tag} (mode=$mode)"
}

snap_png() { snap "${1:-snap}" 1; }
snap_xml() { snap "${1:-snap}" 2; }
