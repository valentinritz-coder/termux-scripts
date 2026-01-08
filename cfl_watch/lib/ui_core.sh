#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# UI core primitives for CFL Watch scenarios.
# Depends on: inject, warn, log (from lib/common.sh), and adb serial setup.
#
# Provides:
#   resid_regex
#   dump_ui
#   wait_dump_grep
#   wait_resid_present
#   wait_resid_absent
#   wait_results_ready
#
# Env knobs:
#   CFL_TMP_DIR, CFL_REMOTE_TMP_DIR, CFL_DUMP_TIMING
#   WAIT_POLL, WAIT_SHORT, WAIT_LONG

: "${CFL_TMP_DIR:=$HOME/.cache/cfl_watch}"
: "${CFL_REMOTE_TMP_DIR:=/data/local/tmp/cfl_watch}"
: "${CFL_DUMP_TIMING:=1}"

: "${WAIT_POLL:=0.0}"
: "${WAIT_SHORT:=20}"
: "${WAIT_LONG:=30}"

# --------
# helpers
# --------

_sleep_if_needed(){
  local s="${1:-0}"
  # sleep 0 / 0.0 is OK, but we skip to avoid syscall spam
  if [[ "$s" =~ ^0(\.0+)?$ ]]; then
    return 0
  fi
  sleep "$s"
}

regex_escape_ere(){
  # Escape a string so it can be safely injected into grep -E patterns.
  # (ERE special chars: . ^ $ * + ? ( ) [ ] { } | \ )
  printf '%s' "$1" | sed -e 's/[.[\](){^$*+?|\\]/\\&/g'
}

# -------------------------
# resource-id regex helper
# -------------------------

resid_regex(){
  # If resid is ":id/foo" -> resource-id="ANY:id/foo"
  local resid="$1"
  if [[ "$resid" == :id/* ]]; then
    local suffix="${resid#:id/}"
    printf 'resource-id="[^"]*:id/%s"' "$suffix"
  else
    # escape dots for regex
    printf 'resource-id="%s"' "${resid//./\\.}"
  fi
}

# -------------------------
# UI dump (remote -> local)
# -------------------------

dump_ui(){
  local remote_dir="$CFL_REMOTE_TMP_DIR"
  local remote_path="$remote_dir/live_dump.xml"

  local local_dir="$CFL_TMP_DIR"
  local local_path="$local_dir/live_dump.xml"

  mkdir -p "$local_dir" >/dev/null 2>&1 || true
  inject mkdir -p "$remote_dir" >/dev/null 2>&1 || true

  local t0 t1 t2 dump_ms cat_ms total_ms
  t0=$(date +%s%N)

  # Avoid stale
  inject rm -f "$remote_path" >/dev/null 2>&1 || true

  # Dump on device
  inject uiautomator dump --compressed "$remote_path" >/dev/null 2>&1 || true

  # mini retry if empty (transitions)
  if ! inject test -s "$remote_path" >/dev/null 2>&1; then
    sleep 0.10
    inject uiautomator dump --compressed "$remote_path" >/dev/null 2>&1 || true
  fi

  t1=$(date +%s%N)

  if ! inject test -s "$remote_path" >/dev/null 2>&1; then
    warn "dump_ui: remote dump absent/vide: $remote_path"
  fi

  # Pull to Termux: tmp + mv
  local tmp_local="$local_path.tmp.$$"
  if inject cat "$remote_path" > "$tmp_local" 2>/dev/null && [ -s "$tmp_local" ]; then
    mv -f "$tmp_local" "$local_path"
  else
    rm -f "$tmp_local" >/dev/null 2>&1 || true
    warn "dump_ui: impossible de lire $remote_path (fallback sdcard)"

    # Fallback: dump directly to sdcard (keeps working even if cat is blocked)
    local sd_dir="/sdcard/cfl_watch/tmp"
    local sd_path="$sd_dir/live_dump.xml"
    local sd_tmp="$sd_path.tmp.$$"

    inject mkdir -p "$sd_dir" >/dev/null 2>&1 || true
    inject rm -f "$sd_path" >/dev/null 2>&1 || true

    inject uiautomator dump --compressed "$sd_tmp" >/dev/null 2>&1 || true
    if inject test -s "$sd_tmp" >/dev/null 2>&1; then
      inject mv -f "$sd_tmp" "$sd_path" >/dev/null 2>&1 || true
      if inject test -s "$sd_path" >/dev/null 2>&1; then
        local_path="$sd_path"
      else
        warn "dump_ui: fallback sdcard mv failed (no final file): $sd_path"
      fi
    else
      inject rm -f "$sd_tmp" >/dev/null 2>&1 || true
      warn "dump_ui: fallback sdcard dump absent/vide: $sd_tmp"
    fi
  fi

  t2=$(date +%s%N)

  dump_ms=$(( (t1-t0)/1000000 ))
  cat_ms=$(( (t2-t1)/1000000 ))
  total_ms=$(( (t2-t0)/1000000 ))

  if [ ! -s "$local_path" ]; then
    warn "UI dump absent/vide: $local_path"
  elif ! grep -q "<hierarchy" "$local_path" 2>/dev/null; then
    warn "UI dump invalide (pas de <hierarchy): $local_path"
  fi

  if [ "${CFL_DUMP_TIMING:-1}" = "1" ]; then
    printf '[*] ui_dump: dump=%sms cat=%sms total=%sms -> %s\n' \
      "$dump_ms" "$cat_ms" "$total_ms" "$local_path" >&2
  fi

  printf '%s' "$local_path"
}

# -------------------------
# Wait helpers (dump + grep)
# -------------------------

wait_dump_grep(){
  # usage: wait_dump_grep "<regex>" [timeout_s] [interval_s]
  local regex="$1"
  local timeout_s="${2:-$WAIT_SHORT}"
  local interval_s="${3:-$WAIT_POLL}"
  local end=$(( $(date +%s) + timeout_s ))

  while [ "$(date +%s)" -lt "$end" ]; do
    local d
    d="$(dump_ui)"
    if grep -Eq "$regex" "$d" 2>/dev/null; then
      printf '%s' "$d"
      return 0
    fi
    _sleep_if_needed "$interval_s"
  done

  warn "wait_dump_grep timeout: regex=$regex"
  return 1
}

wait_resid_present(){
  local resid="$1"
  local timeout_s="${2:-$WAIT_SHORT}"
  local interval_s="${3:-$WAIT_POLL}"
  wait_dump_grep "$(resid_regex "$resid")" "$timeout_s" "$interval_s" >/dev/null
}

wait_resid_absent(){
  local resid="$1"
  local timeout_s="${2:-$WAIT_SHORT}"
  local interval_s="${3:-$WAIT_POLL}"
  local stable_n="${4:-2}"
  local end=$(( $(date +%s) + timeout_s ))
  local pat; pat="$(resid_regex "$resid")"

  local ok=0
  while [ "$(date +%s)" -lt "$end" ]; do
    local d; d="$(dump_ui)"
    if grep -Eq "$pat" "$d" 2>/dev/null; then
      ok=0
    else
      ok=$((ok+1))
      [ "$ok" -ge "$stable_n" ] && return 0
    fi
    _sleep_if_needed "$interval_s"
  done

  warn "wait_resid_absent timeout: resid=$resid"
  return 1
}

wait_results_ready(){
  # Wait for suggestions list after typing.
  local timeout_s="${1:-$WAIT_LONG}"
  local interval_s="${2:-$WAIT_POLL}"

  local re_list='resource-id="[^"]*:id/list_location_results"'
  local re_loader='resource-id="[^"]*:id/progress_location_loading"'
  local end=$(( $(date +%s) + timeout_s ))

  local iter=0 last_state="" m=""
  while [ "$(date +%s)" -lt "$end" ]; do
    iter=$((iter+1))
    local d; d="$(dump_ui)"

    m="$(grep -Eo "$re_list|$re_loader" "$d" 2>/dev/null | tr '\n' ' ' || true)"
    local has_list=0 has_loader=0
    [[ "$m" == *list_location_results* ]] && has_list=1
    [[ "$m" == *progress_location_loading* ]] && has_loader=1

    local state="iter=$iter list=$has_list loader=$has_loader"
    if [ "${CFL_DUMP_TIMING:-1}" = "1" ] && [ "$state" != "$last_state" ]; then
      log "wait_results_ready: $state"
      last_state="$state"
    fi

    # OK if list present (loader optional)
    if [ "$has_list" -eq 1 ] && [ "$has_loader" -eq 0 ]; then
      return 0
    fi
    if [ "$has_list" -eq 1 ]; then
      return 0
    fi

    _sleep_if_needed "$interval_s"
  done

  warn "wait_results_ready timeout ($timeout_s s) last=$last_state"
  return 1
}
