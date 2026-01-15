#!/data/data/com.termux/files/usr/bin/bash
set -u

# Batch runner for trips.txt
#
# Accepted line formats:
#   START|TARGET
#   START|TARGET|SNAP
#   START|TARGET|VIA
#   START|TARGET|VIA|SNAP
#
# Notes:
# - SNAP must be numeric
# - VIA is treated as free text
# - App & scenario selection handled by runner.sh
#
# Usage:
#   CFL_PKG=de.hafas.android.cfl bash batch_trips.sh
#   CFL_MULTI_RUN=1 bash batch_trips.sh

TRIPS_FILE="${TRIPS_FILE:-$HOME/termux-scripts/cfl_watch/trips.txt}"
RUNNER="${RUNNER:-$HOME/termux-scripts/cfl_watch/runner.sh}"

# Defaults (override via env)
ADB_TCP_PORT="${ADB_TCP_PORT:-37099}"
CFL_REMOTE_TMP_DIR="${CFL_REMOTE_TMP_DIR:-/data/local/tmp/cfl_watch}"
CFL_TMP_DIR="${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}"
DEFAULT_SNAP_MODE="${DEFAULT_SNAP_MODE:-3}"
NO_ANIM="${NO_ANIM:-1}"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
_trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_is_number() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# ------------------------------------------------------------
# Sanity checks
# ------------------------------------------------------------
if [ ! -f "$TRIPS_FILE" ]; then
  echo "[!] trips file not found: $TRIPS_FILE" >&2
  exit 1
fi

if [ ! -x "$RUNNER" ]; then
  echo "[!] runner not executable / not found: $RUNNER" >&2
  exit 1
fi

# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------
ok=0
fail=0
i=0

while IFS= read -r line || [ -n "${line:-}" ]; do
  line="$(_trim "$line")"
  [ -z "$line" ] && continue
  [[ "$line" == \#* ]] && continue

  i=$((i+1))

  IFS='|' read -r a b c d <<<"$line"
  a="$(_trim "${a:-}")"
  b="$(_trim "${b:-}")"
  c="$(_trim "${c:-}")"
  d="$(_trim "${d:-}")"

  start="$a"
  target="$b"
  via=""
  snap="$DEFAULT_SNAP_MODE"

  if [ -n "$c" ] && _is_number "$c"; then
    snap="$c"
  elif [ -n "$c" ]; then
    via="$c"
  fi

  if [ -n "$d" ]; then
    if _is_number "$d"; then
      snap="$d"
    else
      echo "[!] line $i invalid (SNAP must be numeric): $line" >&2
      fail=$((fail+1))
      continue
    fi
  fi

  if [ -z "$start" ] || [ -z "$target" ]; then
    echo "[!] line $i invalid (need START|TARGET): $line" >&2
    fail=$((fail+1))
    continue
  fi

  echo "[*] ($i) RUN: $start -> $target${via:+ via $via} | snap=$snap"

  args=()
  [ "$NO_ANIM" = "1" ] && args+=(--no-anim)
  args+=(--start "$start" --target "$target" --snap-mode "$snap")
  [ -n "$via" ] && args+=(--via "$via")

  ADB_TCP_PORT="$ADB_TCP_PORT" \
  CFL_REMOTE_TMP_DIR="$CFL_REMOTE_TMP_DIR" \
  CFL_TMP_DIR="$CFL_TMP_DIR" \
  bash "$RUNNER" "${args[@]}"
  rc=$?

  if [ "$rc" -eq 0 ]; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
    echo "[!] ($i) FAILED rc=$rc : $start -> $target" >&2
  fi

done < "$TRIPS_FILE"

echo "[*] DONE: ok=$ok fail=$fail total=$((ok+fail))"
[ "$fail" -eq 0 ] || exit 1
