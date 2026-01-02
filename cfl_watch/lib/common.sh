#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Common helpers and defaults for CFL automation scripts.
# This file is intended to be sourced, not executed directly.

expand_path(){
  case "${1:-}" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "${1/#\~/$HOME}" ;;
    *) printf '%s' "${1:-}" ;;
  esac
}

_raw_code_dir="${CFL_CODE_DIR:-${CFL_BASE_DIR:-~/cfl_watch}}"
_raw_artifact_dir="${CFL_ARTIFACT_DIR:-/sdcard/cfl_watch}"

CFL_CODE_DIR="$(expand_path "$_raw_code_dir")"
CFL_BASE_DIR="$CFL_CODE_DIR" # backward compatibility alias
CFL_ARTIFACT_DIR="$(expand_path "$_raw_artifact_dir")"
CFL_LOG_DIR="$CFL_ARTIFACT_DIR/logs"
CFL_RUNS_DIR="$CFL_ARTIFACT_DIR/runs"
CFL_TMP_DIR="$CFL_CODE_DIR/tmp"
CFL_SCENARIO_DIR="$CFL_CODE_DIR/scenarios"
CFL_VIEWER_DIR_NAME="viewers"

export CFL_CODE_DIR CFL_BASE_DIR CFL_ARTIFACT_DIR CFL_LOG_DIR CFL_RUNS_DIR CFL_TMP_DIR

CFL_PKG="${CFL_PKG:-de.hafas.android.cfl}"

CFL_DEFAULT_PORT="${ADB_TCP_PORT:-37099}"
CFL_DEFAULT_HOST="${ADB_HOST:-127.0.0.1}"

CFL_SERIAL="${ANDROID_SERIAL:-$CFL_DEFAULT_HOST:$CFL_DEFAULT_PORT}"
export ANDROID_SERIAL="$CFL_SERIAL"

log(){ printf '[*] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[!!] %s\n' "$*" >&2; exit 1; }

need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

ensure_dirs(){
  mkdir -p "$CFL_CODE_DIR" "$CFL_TMP_DIR" "$CFL_ARTIFACT_DIR" "$CFL_LOG_DIR" "$CFL_RUNS_DIR" "$CFL_SCENARIO_DIR"
}

# Normalize text for filenames (safe-ish for Termux)
safe_name(){ printf '%s' "$1" | tr ' /' '__' | tr -cd 'A-Za-z0-9._-'; }

# Record a log file path and tee stdout/stderr there
attach_log(){
  local tag="$1"
  ensure_dirs
  local ts log_path
  ts="$(date +%Y-%m-%d_%H-%M-%S)"
  log_path="$CFL_LOG_DIR/${ts}_${tag}.log"
  exec > >(tee -a "$log_path") 2>&1
  log "Log: $log_path"
  export CFL_LOG_FILE="$log_path"
}

# ADB wrapper for shell commands
inject(){ adb -s "$CFL_SERIAL" shell "$@"; }

tap(){ inject input tap "$1" "$2" >/dev/null 2>&1 || true; }
key(){ inject input keyevent "$1" >/dev/null 2>&1 || true; }

type_text(){
  local t="$1"
  t="${t//\'/}"
  t="${t// /%s}"
  inject input text "$t" >/dev/null 2>&1 || true
}

sleep_s(){
  local d="${1:-0.2}"
  sleep "$d"
}

adb_ping(){
  adb -s "$CFL_SERIAL" get-state >/dev/null 2>&1
}

cfl_force_stop(){
  adb -s "$CFL_SERIAL" shell am force-stop "$CFL_PKG" >/dev/null 2>&1 || true
}

cfl_launch(){
  adb -s "$CFL_SERIAL" shell monkey -p "$CFL_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
}

# Dry-run guard: if CFL_DRY_RUN=1 we only log actions
maybe(){
  if [ "${CFL_DRY_RUN:-0}" = "1" ]; then
    log "[dry-run] $*"
  else
    "$@"
  fi
}

latest_run_dir(){
  ls -1dt "$CFL_RUNS_DIR"/* 2>/dev/null | head -n1 || true
}

self_check(){
  ensure_dirs
  need adb
  need python
  log "Code dir: $CFL_CODE_DIR"
  log "Artifacts: $CFL_ARTIFACT_DIR (runs=$CFL_RUNS_DIR logs=$CFL_LOG_DIR)"
  log "Serial: $CFL_SERIAL"
  log "Package: $CFL_PKG"
  adb start-server >/dev/null 2>&1 || true
  if adb_ping; then
    log "Device reachable via adb"
    adb -s "$CFL_SERIAL" shell getprop ro.product.model 2>/dev/null | head -n1 || true
  else
    warn "Device NOT reachable on $CFL_SERIAL"
  fi
}
