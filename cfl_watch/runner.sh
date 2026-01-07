#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/path.sh"

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}")"
CFL_BASE_DIR="$CFL_CODE_DIR"
CFL_ARTIFACT_DIR="$(expand_tilde_path "${CFL_ARTIFACT_DIR:-/sdcard/cfl_watch}")"
CFL_DEFAULT_PORT="${ADB_TCP_PORT:-37099}"
CFL_DEFAULT_HOST="${ADB_HOST:-127.0.0.1}"
CFL_SCENARIO_SCRIPT="${CFL_SCENARIO_SCRIPT:-$CFL_CODE_DIR/scenarios/scenario_trip.sh}"
CFL_SCENARIO_SCRIPT="$(expand_tilde_path "$CFL_SCENARIO_SCRIPT")"
CFL_DRY_RUN="${CFL_DRY_RUN:-0}"
CFL_DISABLE_ANIM="${CFL_DISABLE_ANIM:-0}"

DELAY_LAUNCH="${DELAY_LAUNCH:-1.0}"
DELAY_TAP="${DELAY_TAP:-0.20}"
DELAY_TYPE="${DELAY_TYPE:-0.30}"
DELAY_PICK="${DELAY_PICK:-0.25}"
DELAY_SEARCH="${DELAY_SEARCH:-0.80}"

. "$CFL_CODE_DIR/lib/common.sh"

usage(){
  cat <<'EOF'
Usage: ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/runner.sh" [options]
--scenario PATH      Scenario script (default: scenarios/scenario_trip.sh)
--start TEXT         Override start location (single-run mode)
--target TEXT        Override destination (single-run mode)
--snap-mode N        Override SNAP_MODE for single run (0-3)
--instruction TEXT   Instruction LLM (déclenche scenario_llm_explore.sh)
--latest-run         Print newest run directory and exit
--serve              Generate/serve latest viewer (python -m http.server)
--dry-run            Log actions without input events
--list               Show bundled scenarios and exit
--check              Run self-check and exit
--no-anim            Disable system animations during the run (restore after)
EOF
}

print_list(){
  cat <<'EOF'
Bundled scenarios (START|TARGET|SNAP_MODE|DELAY_LAUNCH|DELAY_TAP|DELAY_TYPE|DELAY_PICK|DELAY_SEARCH):
LUXEMBOURG|ARLON|3|1.0|0.20|0.30|0.25|0.80
EOF
}

SCENARIOS=(
  "LUXEMBOURG|ARLON|3|5.0|0.20|0.30|0.25|0.80"
)

CUSTOM_START=""
CUSTOM_TARGET=""
CUSTOM_SNAP_MODE=""

LLM_INSTRUCTION="${LLM_INSTRUCTION:-}"


latest_run(){
  ensure_dirs
  local latest
  latest="$(latest_run_dir)"
  if [ -z "$latest" ]; then
    warn "No runs found under $CFL_RUNS_DIR"
    return 1
  fi
  printf '%s\n' "$latest"
}

serve_latest(){
  local latest viewer_dir port
  need python
  latest="$(latest_run)" || die "No runs found under $CFL_RUNS_DIR"
  viewer_dir="$latest/viewers"
  if [ ! -f "$viewer_dir/index.html" ]; then
    log "Generate viewer for $latest"
    bash "$CFL_CODE_DIR/lib/viewer.sh" "$latest"
  fi
  port="${CFL_HTTP_PORT:-8000}"
  cd "$viewer_dir"
  log "Serving latest viewer from: $viewer_dir (port $port)"
  python -m http.server "$port"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scenario)
      [ $# -ge 2 ] || die "--scenario requires a PATH"
      CFL_SCENARIO_SCRIPT="$2"; shift 2 ;;
    --start)
      [ $# -ge 2 ] || die "--start requires TEXT"
      CUSTOM_START="$2"; shift 2 ;;
    --target)
      [ $# -ge 2 ] || die "--target requires TEXT"
      CUSTOM_TARGET="$2"; shift 2 ;;
    --snap-mode)
      [ $# -ge 2 ] || die "--snap-mode requires N"
      CUSTOM_SNAP_MODE="$2"; shift 2 ;;
    --instruction)
      [ $# -ge 2 ] || die "--instruction requires TEXT"
      LLM_INSTRUCTION="$2"; shift 2 ;;
    --dry-run) CFL_DRY_RUN=1; shift ;;
    --latest-run) latest_run; exit $? ;;
    --serve) serve_latest; exit $? ;;
    --list) print_list; exit 0 ;;
    --check) self_check; exit 0 ;;
    --no-anim) CFL_DISABLE_ANIM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done


ensure_dirs
attach_log "runner"
need adb
need python

[ -f "$CFL_CODE_DIR/lib/adb_local.sh" ] || die "Missing: $CFL_CODE_DIR/lib/adb_local.sh"
# If instruction provided, force LLM scenario BEFORE checking file existence
if [ -n "$LLM_INSTRUCTION" ]; then
  CFL_SCENARIO_SCRIPT="$CFL_CODE_DIR/scenarios/scenario_llm_tripplanner.sh"
fi

[ -f "$CFL_SCENARIO_SCRIPT" ] || die "Scenario introuvable: $CFL_SCENARIO_SCRIPT"

chmod +x "$CFL_CODE_DIR"/lib/*.sh "$CFL_CODE_DIR"/scenarios/*.sh "$CFL_CODE_DIR"/tools/*.sh >/dev/null 2>&1 || true

ANIM_W=""
ANIM_T=""
ANIM_A=""

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

cleanup(){
  if [ "$CFL_DISABLE_ANIM" = "1" ]; then
    restore_animations
  fi
  ADB_TCP_PORT="$CFL_DEFAULT_PORT" ADB_HOST="$CFL_DEFAULT_HOST" "$CFL_CODE_DIR/lib/adb_local.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Start ADB local on ${CFL_DEFAULT_HOST}:${CFL_DEFAULT_PORT}"
ADB_TCP_PORT="$CFL_DEFAULT_PORT" ADB_HOST="$CFL_DEFAULT_HOST" "$CFL_CODE_DIR/lib/adb_local.sh" start
log "Device list:"
adb devices -l || true

if [ "$CFL_DISABLE_ANIM" = "1" ]; then
  disable_animations
fi

run_one(){
  local start="$1" target="$2" snap_mode="$3"
  local d_launch="$4" d_tap="$5" d_type="$6" d_pick="$7" d_search="$8"

  log "=== RUN: $start -> $target (SNAP_MODE=$snap_mode) ==="

  # clean state + cold start
  cfl_force_stop
  sleep_s 0.7
  cfl_launch
  sleep_s 5

  local before_latest after_latest
  before_latest="$(latest_run_dir)"

  set +e
  env \
    CFL_CODE_DIR="$CFL_CODE_DIR" \
    CFL_ARTIFACT_DIR="$CFL_ARTIFACT_DIR" \
    START_TEXT="$start" \
    TARGET_TEXT="$target" \
    SNAP_MODE="$snap_mode" \
    DELAY_LAUNCH="$d_launch" \
    DELAY_TAP="$d_tap" \
    DELAY_TYPE="$d_type" \
    DELAY_PICK="$d_pick" \
    DELAY_SEARCH="$d_search" \
    CFL_DRY_RUN="$CFL_DRY_RUN" \
    LLM_INSTRUCTION="$LLM_INSTRUCTION" \
    bash "$CFL_SCENARIO_SCRIPT"
  local rc=$?
  set -e

  log "RC=$rc"

  cfl_force_stop
  sleep_s 0.8

  after_latest="$(latest_run_dir)"
  if [ -n "$after_latest" ] && [ "$after_latest" != "$before_latest" ]; then
    log "Run artifacts: $after_latest"
    [ -f "$after_latest/viewers/index.html" ] && log "Viewer: $after_latest/viewers/index.html"
  fi

  return "$rc"
}

fail_count=0

if [ -n "$LLM_INSTRUCTION" ]; then
  # utilise des placeholders, runner exige start/target pour logger
  run_one "LLM" "LLM" "${CUSTOM_SNAP_MODE:-3}" \
    "$DELAY_LAUNCH" "$DELAY_TAP" "$DELAY_TYPE" "$DELAY_PICK" "$DELAY_SEARCH" \
    || fail_count=$((fail_count+1))
  log "Done. fail_count=$fail_count"
  exit 0
fi

if [ -n "$CUSTOM_START" ] || [ -n "$CUSTOM_TARGET" ]; then
  [ -n "$CUSTOM_START" ] || die "--start required"
  [ -n "$CUSTOM_TARGET" ] || die "--target required"
  snap_mode="${CUSTOM_SNAP_MODE:-1}"
  run_one "$CUSTOM_START" "$CUSTOM_TARGET" "$snap_mode" \
    "$DELAY_LAUNCH" "$DELAY_TAP" "$DELAY_TYPE" "$DELAY_PICK" "$DELAY_SEARCH" \
    || fail_count=$((fail_count+1))
else
  for row in "${SCENARIOS[@]}"; do
    IFS='|' read -r START TARGET SM DLAUNCH DTAP DTYPE DPICK DSEARCH <<<"$row"
    SM="${SM:-1}"; DLAUNCH="${DLAUNCH:-1.0}"; DTAP="${DTAP:-0.20}"
    DTYPE="${DTYPE:-0.30}"; DPICK="${DPICK:-0.25}"; DSEARCH="${DSEARCH:-0.80}"
    run_one "$START" "$TARGET" "$SM" "$DLAUNCH" "$DTAP" "$DTYPE" "$DPICK" "$DSEARCH" \
      || fail_count=$((fail_count+1))
  done
fi

log "Done. fail_count=$fail_count"
exit 0
