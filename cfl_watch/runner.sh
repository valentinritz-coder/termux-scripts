#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

CFL_BASE_DIR="${CFL_BASE_DIR:-/sdcard/cfl_watch}"
CFL_DEFAULT_PORT="${ADB_TCP_PORT:-37099}"
CFL_DEFAULT_HOST="${ADB_HOST:-127.0.0.1}"
CFL_SCENARIO_SCRIPT="${CFL_SCENARIO_SCRIPT:-$CFL_BASE_DIR/scenarios/scenario_trip.sh}"
CFL_DRY_RUN="${CFL_DRY_RUN:-0}"
DELAY_LAUNCH="${DELAY_LAUNCH:-1.0}"
DELAY_TAP="${DELAY_TAP:-0.20}"
DELAY_TYPE="${DELAY_TYPE:-0.30}"
DELAY_PICK="${DELAY_PICK:-0.25}"
DELAY_SEARCH="${DELAY_SEARCH:-0.80}"

. "$CFL_BASE_DIR/lib/common.sh"

usage(){
  cat <<'EOF'
Usage: ADB_TCP_PORT=37099 bash /sdcard/cfl_watch/runner.sh [options]
  --scenario PATH          Scenario script (default: scenarios/scenario_trip.sh)
  --start TEXT             Override start location (single-run mode)
  --target TEXT            Override destination (single-run mode)
  --snap-mode N            Override SNAP_MODE for single run (0-3)
  --dry-run                Log actions without input events
  --list                   Show bundled scenarios and exit
  --check                  Run self-check and exit
EOF
}

print_list(){
  cat <<'EOF'
Bundled scenarios (START|TARGET|SNAP_MODE|DELAY_LAUNCH|DELAY_TAP|DELAY_TYPE|DELAY_PICK|DELAY_SEARCH):
  LUXEMBOURG|ARLON|1|1.0|0.20|0.30|0.25|0.80
  ESCH-SUR-ALZETTE|LUXEMBOURG|1|1.0|0.20|0.30|0.25|0.80
EOF
}

SCENARIOS=(
  "LUXEMBOURG|ARLON|1|1.0|0.20|0.30|0.25|0.80"
  "ESCH-SUR-ALZETTE|LUXEMBOURG|1|1.0|0.20|0.30|0.25|0.80"
)

CUSTOM_START=""
CUSTOM_TARGET=""
CUSTOM_SNAP_MODE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --scenario) CFL_SCENARIO_SCRIPT="$2"; shift 2 ;;
    --start) CUSTOM_START="$2"; shift 2 ;;
    --target) CUSTOM_TARGET="$2"; shift 2 ;;
    --snap-mode) CUSTOM_SNAP_MODE="$2"; shift 2 ;;
    --dry-run) CFL_DRY_RUN=1; shift ;;
    --list) print_list; exit 0 ;;
    --check) self_check; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

ensure_dirs
attach_log "runner"
need adb
need python
[ -f "$CFL_BASE_DIR/lib/adb_local.sh" ] || die "Missing: $CFL_BASE_DIR/lib/adb_local.sh"
[ -f "$CFL_SCENARIO_SCRIPT" ] || die "Scenario introuvable: $CFL_SCENARIO_SCRIPT"
chmod +x "$CFL_BASE_DIR"/lib/*.sh "$CFL_BASE_DIR"/scenarios/*.sh >/dev/null 2>&1 || true

cleanup(){
  CFL_DRY_RUN=0 ADB_TCP_PORT="$CFL_DEFAULT_PORT" ADB_HOST="$CFL_DEFAULT_HOST" "$CFL_BASE_DIR/lib/adb_local.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Start ADB local on ${CFL_DEFAULT_HOST}:${CFL_DEFAULT_PORT}"
ADB_TCP_PORT="$CFL_DEFAULT_PORT" ADB_HOST="$CFL_DEFAULT_HOST" "$CFL_BASE_DIR/lib/adb_local.sh" start
log "Device list:"; adb devices -l || true

run_one(){
  local start="$1" target="$2" snap_mode="$3"
  local d_launch="$4" d_tap="$5" d_type="$6" d_pick="$7" d_search="$8"

  log "=== RUN: $start -> $target (SNAP_MODE=$snap_mode) ==="
  cfl_force_stop
  sleep_s 0.6

  local before_latest after_latest
  before_latest="$(ls -1dt "$CFL_RUNS_DIR"/* 2>/dev/null | head -n1 || true)"

  set +e
  CFL_BASE_DIR="$CFL_BASE_DIR" \
  START_TEXT="$start" TARGET_TEXT="$target" SNAP_MODE="$snap_mode" \
  DELAY_LAUNCH="$d_launch" DELAY_TAP="$d_tap" DELAY_TYPE="$d_type" \
  DELAY_PICK="$d_pick" DELAY_SEARCH="$d_search" CFL_DRY_RUN="$CFL_DRY_RUN" \
  bash "$CFL_SCENARIO_SCRIPT"
  local rc=$?
  set -e

  log "RC=$rc"
  cfl_force_stop
  sleep_s 0.8

  after_latest="$(ls -1dt "$CFL_RUNS_DIR"/* 2>/dev/null | head -n1 || true)"
  if [ -n "$after_latest" ] && [ "$after_latest" != "$before_latest" ]; then
    log "Run artifacts: $after_latest"
    if [ -f "$after_latest/viewers/index.html" ]; then
      log "Viewer: $after_latest/viewers/index.html"
    fi
  fi

  return "$rc"
}

fail_count=0
idx=0

if [ -n "$CUSTOM_START" ] || [ -n "$CUSTOM_TARGET" ]; then
  start="$CUSTOM_START"; target="$CUSTOM_TARGET"
  [ -n "$start" ] || die "--start required when using single-run mode"
  [ -n "$target" ] || die "--target required when using single-run mode"
  snap_mode="${CUSTOM_SNAP_MODE:-1}"
  run_one "$start" "$target" "$snap_mode" "$DELAY_LAUNCH" "$DELAY_TAP" "$DELAY_TYPE" "$DELAY_PICK" "$DELAY_SEARCH" || fail_count=$((fail_count+1))
else
  for row in "${SCENARIOS[@]}"; do
    idx=$((idx+1))
    IFS='|' read -r START TARGET SNAP_MODE DLAUNCH DTAP DTYPE DPICK DSEARCH <<<"$row"
    SNAP_MODE="${SNAP_MODE:-1}"; DLAUNCH="${DLAUNCH:-1.0}"; DTAP="${DTAP:-0.20}"
    DTYPE="${DTYPE:-0.30}"; DPICK="${DPICK:-0.25}"; DSEARCH="${DSEARCH:-0.80}"
    run_one "$START" "$TARGET" "$SNAP_MODE" "$DLAUNCH" "$DTAP" "$DTYPE" "$DPICK" "$DSEARCH" || fail_count=$((fail_count+1))
  done
fi

log "Done. fail_count=$fail_count"
exit 0
