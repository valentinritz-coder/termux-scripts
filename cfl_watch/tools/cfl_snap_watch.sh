#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/snap.sh"

name="${1:-ui_watch}"
snap_init "$name"

LIVE_XML="$SNAP_DIR/_live.xml"
last=""

log "Watching UI changes -> $SNAP_DIR"
log "Ctrl+C to stop"

while true; do
  adb -s "$SERIAL" shell rm -f "$LIVE_XML" >/dev/null 2>&1 || true
  adb -s "$SERIAL" shell uiautomator dump --compressed "$LIVE_XML" >/dev/null 2>&1 || true

  # ignore invalid dumps
  if ! adb -s "$SERIAL" shell "test -s '$LIVE_XML' && grep -q '<hierarchy' '$LIVE_XML'" >/dev/null 2>&1; then
    sleep 0.4
    continue
  fi

  # hash côté device (plus robuste)
  h="$(adb -s "$SERIAL" shell "sha1sum '$LIVE_XML' 2>/dev/null | awk '{print \$1}'" | tr -d '\r' || true)"
  if [ -n "$h" ] && [ "$h" != "$last" ]; then
    last="$h"
    snap "change_${h:0:6}" 3
    adb -s "$SERIAL" shell "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' | head -n 2" > "$SNAP_DIR/$(date +%H-%M-%S)_focus.meta" 2>/dev/null || true
  fi

  sleep 0.4
done
