#!/data/data/com.termux/files/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-/sdcard/cfl_ui_dumps}"
TMP="$OUT_DIR/_live.xml"
mkdir -p "$OUT_DIR"

last_hash=""
ts() { date +"%Y-%m-%d_%H-%M-%S"; }

while true; do
  rm -f "$TMP" || true
  uiautomator dump --compressed "$TMP" >/dev/null 2>&1 || true

  if [ ! -s "$TMP" ] || ! grep -q "<hierarchy" "$TMP" 2>/dev/null; then
    sleep 0.5
    continue
  fi

  h="$(sha1sum "$TMP" | awk '{print $1}')"
  if [ "$h" != "$last_hash" ]; then
    last_hash="$h"
    t="$(ts)"
    cp "$TMP" "$OUT_DIR/${t}.xml"
    screencap -p "$OUT_DIR/${t}.png" >/dev/null 2>&1 || true
    dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' | head -n 2 > "$OUT_DIR/${t}.meta" || true
    echo "[*] change detected -> ${t}"
  fi

  sleep 0.4
done
