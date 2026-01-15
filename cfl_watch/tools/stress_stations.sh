#!/data/data/com.termux/files/usr/bin/bash
set -u

# Stress test: pick random start/target (and optional via) from stations.txt
#
# App & scenario selection handled by runner.sh
# - mono-run via CFL_PKG
# - multi-run via CFL_MULTI_RUN=1

STATIONS_FILE="${STATIONS_FILE:-$HOME/termux-scripts/cfl_watch/stations.txt}"
RUNNER="${RUNNER:-$HOME/termux-scripts/cfl_watch/runner.sh}"

# Defaults (override via env)
ADB_TCP_PORT="${ADB_TCP_PORT:-37099}"
CFL_REMOTE_TMP_DIR="${CFL_REMOTE_TMP_DIR:-/data/local/tmp/cfl_watch}"
CFL_TMP_DIR="${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}"
SNAP_MODE="${SNAP_MODE:-3}"
NO_ANIM="${NO_ANIM:-1}"

# Stress params
N="${N:-10}"                     # number of runs
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0}"
ALLOW_VIA="${ALLOW_VIA:-0}"      # 1 = enable via
VIA_PROB="${VIA_PROB:-50}"       # % chance to add a via when enabled

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
_trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_rand_station() {
  echo "${stations[$RANDOM % count]}"
}

# ------------------------------------------------------------
# Sanity checks
# ------------------------------------------------------------
if [ ! -f "$STATIONS_FILE" ]; then
  echo "[!] stations file not found: $STATIONS_FILE" >&2
  exit 1
fi

if [ ! -x "$RUNNER" ]; then
  echo "[!] runner not executable / not found: $RUNNER" >&2
  exit 1
fi

# ------------------------------------------------------------
# Load stations
# ------------------------------------------------------------
stations=()
while IFS= read -r line || [ -n "${line:-}" ]; do
  line="$(_trim "$line")"
  [ -z "$line" ] && continue
  [[ "$line" == \#* ]] && continue
  stations+=("$line")
done < "$STATIONS_FILE"

count="${#stations[@]}"
if [ "$count" -lt 2 ]; then
  echo "[!] need at least 2 stations in $STATIONS_FILE" >&2
  exit 1
fi

echo "[*] stations loaded: $count"
echo "[*] stress: N=$N snap=$SNAP_MODE via=$ALLOW_VIA (prob=${VIA_PROB}%)"

# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------
ok=0
fail=0

for i in $(seq 1 "$N"); do
  start="$(_rand_station)"
  target="$(_rand_station)"

  # ensure start != target
  tries=0
  while [ "$start" = "$target" ] && [ "$tries" -lt 5 ]; do
    target="$(_rand_station)"
    tries=$((tries+1))
  done
  [ "$start" = "$target" ] && target="$(_rand_station)"

  via=""

  if [ "$ALLOW_VIA" = "1" ]; then
    if [ $((RANDOM % 100)) -lt "$VIA_PROB" ]; then
      tries=0
      while :; do
        via="$(_rand_station)"
        [ "$via" != "$start" ] && [ "$via" != "$target" ] && break
        tries=$((tries+1))
        [ "$tries" -ge 5 ] && via="" && break
      done
    fi
  fi

  if [ -n "$via" ]; then
    echo "[*] ($i/$N) RUN: $start -> $target via $via"
  else
    echo "[*] ($i/$N) RUN: $start -> $target"
  fi

  args=()
  [ "$NO_ANIM" = "1" ] && args+=(--no-anim)
  args+=(--start "$start" --target "$target" --snap-mode "$SNAP_MODE")
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
    echo "[!] ($i/$N) FAILED rc=$rc : $start -> $target" >&2
  fi

  [ "$SLEEP_BETWEEN" != "0" ] && sleep "$SLEEP_BETWEEN"
done

echo "[*] DONE: ok=$ok fail=$fail total=$((ok+fail))"
[ "$fail" -eq 0 ] || exit 1
