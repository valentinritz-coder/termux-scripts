#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

SNAP_MODE_SET=0
if [ "${SNAP_MODE+set}" = "set" ]; then
  SNAP_MODE_SET=1
fi

CFL_CODE_DIR="${CFL_CODE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CFL_CODE_DIR="$(expand_tilde_path "$CFL_CODE_DIR")"
CFL_BASE_DIR="${CFL_BASE_DIR:-$CFL_CODE_DIR}"

if [ -f "$CFL_CODE_DIR/env.sh" ]; then
  . "$CFL_CODE_DIR/env.sh"
fi
if [ -f "$CFL_CODE_DIR/env.local.sh" ]; then
  . "$CFL_CODE_DIR/env.local.sh"
fi

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}")"
CFL_BASE_DIR="${CFL_BASE_DIR:-$CFL_CODE_DIR}"

. "$CFL_CODE_DIR/lib/common.sh"
. "$CFL_CODE_DIR/lib/snap.sh"

if [ "$SNAP_MODE_SET" -eq 0 ]; then
  SNAP_MODE=3
fi

name="${1:-ui_watch}"
snap_init "$name"

LIVE_XML="$SNAP_DIR/_live.xml"
last=""

log "SERIAL=$SERIAL"
log "Watching UI changes -> $SNAP_DIR"
log "Ctrl+C to stop"

# Always take one snapshot so you instantly see files
snap "00_initial" 3

hash_live_xml(){
  # Hash locally in Termux, so we don't depend on sha1sum inside adb shell
  adb -s "$SERIAL" exec-out cat "$LIVE_XML" 2>/dev/null | sha1sum | awk '{print $1}'
}

while true; do
  # Dump a live xml on the device
  adb -s "$SERIAL" shell "rm -f '$LIVE_XML' >/dev/null 2>&1 || true; uiautomator dump --compressed '$LIVE_XML' >/dev/null 2>&1 || exit 2" \
    || { warn "uiautomator dump failed (adb rc=$?)"; sleep 0.5; continue; }

  # Check file exists + non-empty (on device)
  if ! adb -s "$SERIAL" shell "test -s '$LIVE_XML'" >/dev/null 2>&1; then
    warn "live xml missing/empty: $LIVE_XML"
    sleep 0.4
    continue
  fi

  h="$(hash_live_xml | tr -d '\r')"
  if [ -z "$h" ]; then
    warn "hash empty (adb exec-out cat failed?)"
    sleep 0.4
    continue
  fi

  if [ "$h" != "$last" ]; then
    last="$h"
    snap "change_${h:0:6}" 3
    adb -s "$SERIAL" shell "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' | head -n 2" \
      > "$SNAP_DIR/$(date +%H-%M-%S)_focus.meta" 2>/dev/null || true
  fi

  sleep 0.4
done
