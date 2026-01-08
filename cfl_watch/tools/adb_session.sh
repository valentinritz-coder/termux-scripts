#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFL_CODE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Optional path helpers if you use them
if [ -f "$CFL_CODE_DIR/lib/path.sh" ]; then
  # shellcheck source=/dev/null
  . "$CFL_CODE_DIR/lib/path.sh"
  CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-$CFL_CODE_DIR}")"
fi

# env
[ -f "$CFL_CODE_DIR/env.sh" ] && . "$CFL_CODE_DIR/env.sh"
[ -f "$CFL_CODE_DIR/env.local.sh" ] && . "$CFL_CODE_DIR/env.local.sh"

# common helpers (log/warn/die/need/attach_log/ensure_dirs)
# shellcheck source=/dev/null
. "$CFL_CODE_DIR/lib/common.sh"

CFL_DEFAULT_PORT="${ADB_TCP_PORT:-37099}"
CFL_DEFAULT_HOST="${ADB_HOST:-127.0.0.1}"
CFL_DRY_RUN="${CFL_DRY_RUN:-0}"
CFL_DISABLE_ANIM=0

usage() {
  cat <<'EOF'
Usage: adb_session.sh [--no-anim] [--host HOST] [--port PORT] [--dry-run] [--status] [-h]

Starts local ADB TCP session (via lib/adb_local.sh), optionally disables Android animations,
then waits until Ctrl+C. On exit, restores animations and stops ADB local.

Options:
  --no-anim        Disable system animations during the session (restored on exit)
  --host HOST      ADB host (default: 127.0.0.1)
  --port PORT      ADB tcp port (default: 37099)
  --dry-run        Do not execute actions, only log
  --status         Print adb devices -l and exit
  -h, --help       Show help

Typical:
  tools/adb_session.sh --no-anim
  # in another Termux session:
  tools/watch_ui_dump.sh -i 2 -o /sdcard/cfl_watch/captures
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-anim) CFL_DISABLE_ANIM=1; shift ;;
    --host) CFL_DEFAULT_HOST="$2"; shift 2 ;;
    --port) CFL_DEFAULT_PORT="$2"; shift 2 ;;
    --dry-run) CFL_DRY_RUN=1; shift ;;
    --status)
      command -v adb >/dev/null 2>&1 || die "adb not found"
      adb devices -l || true
      exit 0
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

ensure_dirs
attach_log "adb_session"
need adb

[ -f "$CFL_CODE_DIR/lib/adb_local.sh" ] || die "Missing: $CFL_CODE_DIR/lib/adb_local.sh"

ANIM_W=""; ANIM_T=""; ANIM_A=""

read_anim_scales() {
  ANIM_W="$(adb shell settings get global window_animation_scale 2>/dev/null | tr -d '\r')"
  ANIM_T="$(adb shell settings get global transition_animation_scale 2>/dev/null | tr -d '\r')"
  ANIM_A="$(adb shell settings get global animator_duration_scale 2>/dev/null | tr -d '\r')"
  [ -n "$ANIM_W" ] && [ "$ANIM_W" != "null" ] || ANIM_W="1"
  [ -n "$ANIM_T" ] && [ "$ANIM_T" != "null" ] || ANIM_T="1"
  [ -n "$ANIM_A" ] && [ "$ANIM_A" != "null" ] || ANIM_A="1"
}

disable_animations() {
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

restore_animations() {
  [ -n "${ANIM_W:-}" ] || return 0
  log "Restore Android animations: W=$ANIM_W T=$ANIM_T A=$ANIM_A"
  adb shell settings put global window_animation_scale "$ANIM_W" >/dev/null 2>&1 || true
  adb shell settings put global transition_animation_scale "$ANIM_T" >/dev/null 2>&1 || true
  adb shell settings put global animator_duration_scale "$ANIM_A" >/dev/null 2>&1 || true
}

cleanup() {
  if [ "$CFL_DISABLE_ANIM" = "1" ] && [ "${CFL_DRY_RUN:-0}" != "1" ]; then
    restore_animations
  fi
  if [ "${CFL_DRY_RUN:-0}" != "1" ]; then
    ADB_TCP_PORT="$CFL_DEFAULT_PORT" ADB_HOST="$CFL_DEFAULT_HOST" "$CFL_CODE_DIR/lib/adb_local.sh" stop >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log "Start ADB local on ${CFL_DEFAULT_HOST}:${CFL_DEFAULT_PORT}"
if [ "${CFL_DRY_RUN:-0}" != "1" ]; then
  ADB_TCP_PORT="$CFL_DEFAULT_PORT" ADB_HOST="$CFL_DEFAULT_HOST" "$CFL_CODE_DIR/lib/adb_local.sh" start
  log "Device list:"
  adb devices -l || true
else
  log "[dry-run] skip adb_local start/devices"
fi

if [ "$CFL_DISABLE_ANIM" = "1" ]; then
  disable_animations
fi

log "ADB session ready. Leave this running. Ctrl+C to stop (will restore anim + stop ADB local)."
while true; do sleep 3600; done
