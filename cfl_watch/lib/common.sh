#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$COMMON_DIR/path.sh"

# Common helpers and defaults for CFL automation scripts.
# This file is intended to be sourced, not executed directly.

_raw_code_dir="${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}"
_raw_artifact_dir="${CFL_ARTIFACT_DIR:-/sdcard/cfl_watch}"

CFL_CODE_DIR="$(expand_tilde_path "$_raw_code_dir")"
CFL_BASE_DIR="$CFL_CODE_DIR" # backward compatibility alias
CFL_ARTIFACT_DIR="$(expand_tilde_path "$_raw_artifact_dir")"
CFL_LOG_DIR="$CFL_ARTIFACT_DIR/logs"
CFL_RUNS_DIR="$CFL_ARTIFACT_DIR/runs"
# tmp must be writable by adb shell for uiautomator dumps.
# Default to sdcard, but allow override from env.
CFL_TMP_DIR="$(expand_tilde_path "${CFL_TMP_DIR:-$CFL_ARTIFACT_DIR/tmp}")"
CFL_SCENARIO_DIR="$CFL_CODE_DIR/scenarios"
CFL_VIEWER_DIR_NAME="viewers"

export CFL_CODE_DIR CFL_BASE_DIR CFL_ARTIFACT_DIR CFL_LOG_DIR CFL_RUNS_DIR CFL_TMP_DIR CFL_SCENARIO_DIR

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

current_activity(){
  # Exemple de sortie: com.package/.MainActivity
  adb shell dumpsys activity activities 2>/dev/null \
    | tr -d '\r' \
    | grep -m1 -E 'mResumedActivity|topResumedActivity' \
    | sed -E 's/.* ([^ ]+) .*/\1/' \
    || true
}

wait_activity(){
  local expected="$1"
  local timeout_s="${2:-12}"
  local interval_s="${3:-0.20}"
  local end=$(( $(date +%s) + timeout_s ))

  while [ "$(date +%s)" -lt "$end" ]; do
    local cur
    cur="$(current_activity)"
    if printf '%s' "$cur" | grep -Fq "$expected"; then
      return 0
    fi
    sleep "$interval_s"
  done

  warn "wait_activity timeout: expected='$expected' got='$(current_activity)'"
  return 1
}

ui_dump(){
  # Dump sur /sdcard puis cat
  # Evite les dossiers qui n'existent pas: fichier direct dans /sdcard
  local tmp="/sdcard/tmp_ui.xml"
  adb shell "uiautomator dump --compressed $tmp >/dev/null 2>&1 && cat $tmp" \
    | tr -d '\r' \
    || true
}

wait_ui_grep(){
  local regex="$1"
  local timeout_s="${2:-10}"
  local interval_s="${3:-0.30}"
  local end=$(( $(date +%s) + timeout_s ))

  while [ "$(date +%s)" -lt "$end" ]; do
    local xml
    xml="$(ui_dump)"
    if printf '%s' "$xml" | grep -Eq "$regex"; then
      return 0
    fi
    sleep "$interval_s"
  done

  warn "wait_ui_grep timeout: regex=$regex"
  return 1
}

wait_ui_text(){
  local text="$1"
  local timeout_s="${2:-10}"
  local interval_s="${3:-0.30}"
  local end=$(( $(date +%s) + timeout_s ))

  while [ "$(date +%s)" -lt "$end" ]; do
    local xml
    xml="$(ui_dump)"
    # fixed-string (évite les surprises regex)
    if printf '%s' "$xml" | grep -Fq "text=\"$text\""; then
      return 0
    fi
    sleep "$interval_s"
  done

  warn "wait_ui_text timeout: text=$text"
  return 1
}

wait_ui_resid(){
  local resid="$1"
  local timeout_s="${2:-10}"
  local interval_s="${3:-0.30}"
  local end=$(( $(date +%s) + timeout_s ))

  while [ "$(date +%s)" -lt "$end" ]; do
    local xml
    xml="$(ui_dump)"
    if printf '%s' "$xml" | grep -Fq "resource-id=\"$resid\""; then
      return 0
    fi
    sleep "$interval_s"
  done

  warn "wait_ui_resid timeout: resid=$resid"
  return 1
}

ime_is_shown(){
  local out vis
  out="$(adb shell dumpsys input_method 2>/dev/null | tr -d '\r' || true)"

  # Cas fréquents selon version Android
  if printf '%s' "$out" | grep -Eq 'mInputShown=true|mIsInputViewShown=true'; then
    return 0
  fi

  # Fallback: visibilité IME en hex (souvent présent)
  vis="$(printf '%s' "$out" | grep -Eo 'mImeWindowVis=0x[0-9a-f]+' | head -n1 | cut -d= -f2)"
  [ -n "$vis" ] || return 1
  [ "$vis" != "0x0" ]
}

wait_keyboard_shown(){
  local timeout_s="${1:-5}"
  local interval_s="${2:-0.15}"
  local end=$(( $(date +%s) + timeout_s ))

  while [ "$(date +%s)" -lt "$end" ]; do
    if ime_is_shown; then
      return 0
    fi
    sleep "$interval_s"
  done

  warn "wait_keyboard_shown timeout"
  return 1
}

wait_keyboard_hidden(){
  local timeout_s="${1:-5}"
  local interval_s="${2:-0.15}"
  local end=$(( $(date +%s) + timeout_s ))

  while [ "$(date +%s)" -lt "$end" ]; do
    if ! ime_is_shown; then
      return 0
    fi
    sleep "$interval_s"
  done

  warn "wait_keyboard_hidden timeout"
  return 1
}

wait_ui_absent_resid(){
  # Attend que le resource-id disparaisse de l'ui.xml
  local resid="$1"
  local timeout_s="${2:-10}"
  local interval_s="${3:-0.30}"
  local stable_n="${4:-2}"   # doit être absent N dumps d'affilée (anti-flicker)
  local end=$(( $(date +%s) + timeout_s ))

  local ok=0
  while [ "$(date +%s)" -lt "$end" ]; do
    local xml
    xml="$(ui_dump)"

    if printf '%s' "$xml" | grep -Fq "resource-id=\"$resid\""; then
      ok=0
    else
      ok=$((ok+1))
      if [ "$ok" -ge "$stable_n" ]; then
        return 0
      fi
    fi

    sleep "$interval_s"
  done

  warn "wait_ui_absent_resid timeout: resid=$resid"
  return 1
}
