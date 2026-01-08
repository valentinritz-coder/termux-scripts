#!/data/data/com.termux/files/usr/bin/bash
set -u

# Stress test: pick random start/target from stations.txt and run N times.

STATIONS_FILE="${STATIONS_FILE:-$HOME/cfl_watch/stations.txt}"
RUNNER="${RUNNER:-$HOME/cfl_watch/runner.sh}"

# Defaults (override via env)
ADB_TCP_PORT="${ADB_TCP_PORT:-37099}"
CFL_REMOTE_TMP_DIR="${CFL_REMOTE_TMP_DIR:-/data/local/tmp/cfl_watch}"
CFL_TMP_DIR="${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}"
SCENARIO="${SCENARIO:-$HOME/cfl_watch/scenarios/trip_api.sh}"
SNAP_MODE="${SNAP_MODE:-3}"
NO_ANIM="${NO_ANIM:-1}"

# Stress params
N="${N:-10}"                 # number of runs
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0}"  # seconds between runs (can be 0)

_trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

if [ ! -f "$STATIONS_FILE" ]; then
  echo "[!] stations file not found: $STATIONS_FILE" >&2
  exit 1
fi
if [ ! -x "$RUNNER" ]; then
  echo "[!] runner not executable / not found: $RUNNER" >&2
  exit 1
fi

# Load stations
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
echo "[*] stress: N=$N snap=$SNAP_MODE scenario=$SCENARIO"

ok=0
fail=0

for i in $(seq 1 "$N"); do
  start="${stations[$RANDOM % count]}"
  target="${stations[$RANDOM % count]}"

  # avoid start==target (retry a few times)
  tries=0
  while [ "$start" = "$target" ] && [ "$tries" -lt 5 ]; do
    target="${stations[$RANDOM % count]}"
    tries=$((tries+1))
  done
  [ "$start" = "$target" ] && target="${stations[(($RANDOM+1) % count)]}"

  echo "[*] ($i/$N) RUN: $start -> $target"

  args=()
  [ "$NO_ANIM" = "1" ] && args+=(--no-anim)
  args+=(--start "$start" --target "$target" --snap-mode "$SNAP_MODE")

  ADB_TCP_PORT="$ADB_TCP_PORT" \
  CFL_REMOTE_TMP_DIR="$CFL_REMOTE_TMP_DIR" \
  CFL_TMP_DIR="$CFL_TMP_DIR" \
  CFL_SCENARIO_SCRIPT="$SCENARIO" \
  bash "$RUNNER" "${args[@]}"
  rc=$?

  if [ "$rc" -eq 0 ]; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
    echo "[!] ($i/$N) FAILED rc=$rc : $start -> $target" >&2
  fi

  if [ "$SLEEP_BETWEEN" != "0" ]; then
    sleep "$SLEEP_BETWEEN"
  fi
done

echo "[*] DONE: ok=$ok fail=$fail total=$((ok+fail))"
[ "$fail" -eq 0 ] || exit 1
