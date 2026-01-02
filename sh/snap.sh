cat > /sdcard/cfl_watch/snap.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="${BASE:-/sdcard/cfl_watch}"
SER="${ANDROID_SERIAL:-127.0.0.1:37099}"

mkdir -p "$BASE"/{runs,tmp,logs}
# testttt
# Usage:
#   snap_init "scenario_name"
#   snap "01_launch"
#   snap "02_after_tap"
# Sets SNAP_DIR env var

snap_init() {
  local name="${1:-run}"
  local ts
  ts="$(date +%Y-%m-%d_%H-%M-%S)"
  export SNAP_DIR="$BASE/runs/${ts}_${name}"
  mkdir -p "$SNAP_DIR"
  echo "[*] SNAP_DIR=$SNAP_DIR"
}

snap() {
  local tag="${1:-snap}"
  local ts
  ts="$(date +%H-%M-%S)"
  # UI dump + screenshot on device storage
  adb -s "$SER" shell uiautomator dump --compressed "$SNAP_DIR/${ts}_${tag}.xml" >/dev/null 2>&1 || true
  adb -s "$SER" shell screencap -p "$SNAP_DIR/${ts}_${tag}.png" >/dev/null 2>&1 || true
  echo "[*] snap: ${ts}_${tag}"
}

SH

chmod +x /sdcard/cfl_watch/snap.sh
sed -i 's/\r$//' /sdcard/cfl_watch/snap.sh 2>/dev/null || true
