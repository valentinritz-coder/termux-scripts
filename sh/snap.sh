#!/data/data/com.termux/files/usr/bin/bash
# Librairie à sourcer: . /sdcard/cfl_watch/snap.sh

snap_init() {
  local name="${1:-run}"
  local base="${BASE:-/sdcard/cfl_watch}"
  local ts
  ts="$(date +%Y-%m-%d_%H-%M-%S)"

  mkdir -p "$base"/{runs,tmp,logs} 2>/dev/null || true
  export SNAP_DIR="$base/runs/${ts}_${name}"
  mkdir -p "$SNAP_DIR" 2>/dev/null || true
  echo "[*] SNAP_DIR=$SNAP_DIR"
}

snap() {
  local tag="${1:-snap}"
  local ser="${ANDROID_SERIAL:-127.0.0.1:37099}"
  local ts
  ts="$(date +%H-%M-%S)"

  if [ -z "${SNAP_DIR:-}" ]; then
    echo "[!] SNAP_DIR non défini. Appelle d'abord: snap_init \"nom\""
    return 1
  fi

  adb -s "$ser" shell uiautomator dump --compressed "$SNAP_DIR/${ts}_${tag}.xml" >/dev/null 2>&1 || true
  adb -s "$ser" shell screencap -p "$SNAP_DIR/${ts}_${tag}.png" >/dev/null 2>&1 || true
  echo "[*] snap: ${ts}_${tag}"
}
