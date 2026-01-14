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

[ -f "$CFL_CODE_DIR/env.sh" ] && . "$CFL_CODE_DIR/env.sh"
[ -f "$CFL_CODE_DIR/env.local.sh" ] && . "$CFL_CODE_DIR/env.local.sh"

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}")"
CFL_BASE_DIR="${CFL_BASE_DIR:-$CFL_CODE_DIR}"

. "$CFL_CODE_DIR/lib/common.sh"
. "$CFL_CODE_DIR/lib/snap.sh"

if [ "$SNAP_MODE_SET" -eq 0 ]; then
  SNAP_MODE=3
fi

command -v sha1sum >/dev/null 2>&1 || { echo "sha1sum introuvable (coreutils manquant?)"; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "awk introuvable"; exit 1; }

name="${1:-ui_watch}"
snap_init "$name"

# UI dump is slow (2-3s). We do stability based on elapsed time, not "N loops".
STABLE_SECS="${STABLE_SECS:-6}"          # wait this long with same UI hash
POLL_SLEEP_S="${POLL_SLEEP_S:-0.2}"      # extra sleep between dumps (dump itself already costs time)
FORCE_INTERVAL_SECS="${FORCE_INTERVAL_SECS:-}"
last_forced_capture=0

# Put the live dump in a temp dir (faster, fewer perms headaches)
REMOTE_TMP_DIR="${CFL_REMOTE_TMP_DIR:-/data/local/tmp/cfl_watch}"
REMOTE_LIVE_XML="${REMOTE_LIVE_XML:-$REMOTE_TMP_DIR/_live.xml}"

log "SERIAL=$SERIAL"
log "Watching UI changes -> $SNAP_DIR"
log "Stability window: ${STABLE_SECS}s"
log "Live XML (device): $REMOTE_LIVE_XML"
log "Ctrl+C to stop"

adb -s "$SERIAL" shell "mkdir -p '$REMOTE_TMP_DIR' >/dev/null 2>&1" || true

read_anim_scales(){
  ANIM_W="$(adb shell settings get global window_animation_scale 2>/dev/null | tr -d '\r')"
  ANIM_T="$(adb shell settings get global transition_animation_scale 2>/dev/null | tr -d '\r')"
  ANIM_A="$(adb shell settings get global animator_duration_scale 2>/dev/null | tr -d '\r')"

  # fallback si "null" ou vide
  [ -n "$ANIM_W" ] && [ "$ANIM_W" != "null" ] || ANIM_W="1"
  [ -n "$ANIM_T" ] && [ "$ANIM_T" != "null" ] || ANIM_T="1"
  [ -n "$ANIM_A" ] && [ "$ANIM_A" != "null" ] || ANIM_A="1"
}

disable_animations(){
  if [ "${CFL_DRY_RUN:-0}" = "1" ]; then
    log "[dry-run] skip animation toggles"
    return 0
  fi
  log "Disable Android animations (temporary)"
  read_anim_scales
  adb shell settings put global window_animation_scale 0 >/dev/null
  adb shell settings put global transition_animation_scale 0 >/dev/null
  adb shell settings put global animator_duration_scale 0 >/dev/null
}

restore_animations(){
  [ -n "${ANIM_W:-}" ] || return 0
  log "Restore Android animations: W=$ANIM_W T=$ANIM_T A=$ANIM_A"
  adb shell settings put global window_animation_scale "$ANIM_W" >/dev/null 2>&1 || true
  adb shell settings put global transition_animation_scale "$ANIM_T" >/dev/null 2>&1 || true
  adb shell settings put global animator_duration_scale "$ANIM_A" >/dev/null 2>&1 || true
}

notify_capture() {
  local msg="$1"

  if command -v termux-toast >/dev/null 2>&1; then
    termux-toast -g middle -s "$msg" >/dev/null 2>&1 || true
    return
  fi

  if command -v termux-notification >/dev/null 2>&1; then
    termux-notification --id "cfl_watch_capture" --title "CFL Watch" --content "$msg" >/dev/null 2>&1 || true
    return
  fi

  # fallback: au pire un log
  log "$msg"
}

hash_remote_xml() {
  # Hash locally in Termux, reading remote file through adb (no sha1sum in adb shell needed)
  adb -s "$SERIAL" exec-out cat "$REMOTE_LIVE_XML" 2>/dev/null | sha1sum | awk '{print $1}'
}

dump_live_xml() {
  # Dump UI to remote temp file (compressed)
  adb -s "$SERIAL" shell "rm -f '$REMOTE_LIVE_XML' >/dev/null 2>&1 || true; uiautomator dump --compressed '$REMOTE_LIVE_XML' >/dev/null 2>&1"
}

capture_pair_from_live() {
  local tag="$1"
  local ts base

  ts="$(date +%Y-%m-%d_%H-%M-%S)"
  base="$SNAP_DIR/${ts}_${tag}"

  # Save EXACT XML that was used for stability/hash
  adb -s "$SERIAL" exec-out cat "$REMOTE_LIVE_XML" > "${base}.ui.xml" 2>/dev/null || true

  # Screenshot immediately after (best effort sync)
  adb -s "$SERIAL" exec-out screencap -p > "${base}.png" 2>/dev/null || true

  # Focus/meta
  {
    echo "ts=$ts"
    echo "tag=$tag"
    echo "stable_secs=$STABLE_SECS"
    adb -s "$SERIAL" shell "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' | head -n 2" 2>/dev/null || true
  } > "${base}.meta" 2>/dev/null || true

  log "Captured: ${base}.{ui.xml,png,meta}"
  notify_capture "📸 Capture: ${tag}"
  command -v termux-vibrate >/dev/null 2>&1 && termux-vibrate -d 80 >/dev/null 2>&1 || true
}

# Take one initial capture (stable not required)
if dump_live_xml; then
  if adb -s "$SERIAL" shell "test -s '$REMOTE_LIVE_XML'" >/dev/null 2>&1; then
    h0="$(hash_remote_xml | tr -d '\r')"
    [ -n "$h0" ] && capture_pair_from_live "initial_${h0:0:6}" || capture_pair_from_live "initial"
  else
    warn "Initial live xml missing/empty: $REMOTE_LIVE_XML"
  fi
else
  warn "Initial uiautomator dump failed"
fi

candidate=""
candidate_since=0
last_captured=""

disable_animations

while true; do

  if [ -n "$FORCE_INTERVAL_SECS" ]; then
    if dump_live_xml && adb -s "$SERIAL" shell "test -s '$REMOTE_LIVE_XML'" >/dev/null 2>&1; then
      now="$(date +%s)"
      if [ $(( now - last_forced_capture )) -ge "$FORCE_INTERVAL_SECS" ]; then
        last_forced_capture="$now"
        capture_pair_from_live "forced_${now}"
      fi
    else
      warn "Forced capture skipped (dump or xml failed)"
    fi
  
    sleep "$POLL_SLEEP_S"
    continue
  fi

  if ! dump_live_xml; then
    warn "uiautomator dump failed (adb rc=$?)"
    sleep "$POLL_SLEEP_S"
    continue
  fi

  if ! adb -s "$SERIAL" shell "test -s '$REMOTE_LIVE_XML'" >/dev/null 2>&1; then
    warn "live xml missing/empty: $REMOTE_LIVE_XML"
    sleep "$POLL_SLEEP_S"
    continue
  fi

  h="$(hash_remote_xml | tr -d '\r')"
  if [ -z "$h" ]; then
    warn "hash empty (adb exec-out cat failed?)"
    sleep "$POLL_SLEEP_S"
    continue
  fi

  now="$(date +%s)"
  
  if [ "$h" != "$candidate" ]; then
    candidate="$h"
    candidate_since="$now"
  else
    # same candidate hash, check stability time
    elapsed=$(( now - candidate_since ))
    if [ "$elapsed" -ge "$STABLE_SECS" ] && [ "$candidate" != "$last_captured" ]; then
      last_captured="$candidate"
      capture_pair_from_live "stable_${candidate:0:6}"
      # keep candidate_since as-is; last_captured prevents re-capturing forever
    fi
  fi
  
  sleep "$POLL_SLEEP_S"
done
