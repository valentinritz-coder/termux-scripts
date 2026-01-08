#!/data/data/com.termux/files/usr/bin/bash
set -u

# Batch runner for trips.txt
# Lines accepted:
#   START|TARGET
#   SCENARIO_SCRIPT|START|TARGET
#   SCENARIO_SCRIPT|START|TARGET|SNAP_MODE
# Comments: lines starting with #, blanks ignored.

TRIPS_FILE="${TRIPS_FILE:-$HOME/termux-scripts/cfl_watch/trips.txt}"
RUNNER="${RUNNER:-$HOME/termux-scripts/cfl_watch/runner.sh}"

# Defaults (override via env)
ADB_TCP_PORT="${ADB_TCP_PORT:-37099}"
CFL_REMOTE_TMP_DIR="${CFL_REMOTE_TMP_DIR:-/data/local/tmp/cfl_watch}"
CFL_TMP_DIR="${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}"
DEFAULT_SCENARIO="${DEFAULT_SCENARIO:-$HOME/termux-scripts/cfl_watch/scenarios/trip_api.sh}"
DEFAULT_SNAP_MODE="${DEFAULT_SNAP_MODE:-3}"
NO_ANIM="${NO_ANIM:-1}"

# Small helper: trim
_trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

if [ ! -f "$TRIPS_FILE" ]; then
  echo "[!] trips file not found: $TRIPS_FILE" >&2
  exit 1
fi
if [ ! -x "$RUNNER" ]; then
  echo "[!] runner not executable / not found: $RUNNER" >&2
  exit 1
fi

ok=0
fail=0
i=0

while IFS= read -r line || [ -n "${line:-}" ]; do
  line="$(_trim "$line")"
  [ -z "$line" ] && continue
  [[ "$line" == \#* ]] && continue

  i=$((i+1))

  # Split by |
  IFS='|' read -r a b c d <<<"$line"
  a="$(_trim "${a:-}")"; b="$(_trim "${b:-}")"; c="$(_trim "${c:-}")"; d="$(_trim "${d:-}")"

  scenario="$DEFAULT_SCENARIO"
  start=""
  target=""
  snap="$DEFAULT_SNAP_MODE"

  # Detect format
  if [[ "$a" == */*".sh"* ]] || [[ "$a" == "$HOME"* ]] || [[ "$a" == /* ]]; then
    # Scenario provided
    scenario="$a"
    start="$b"
    target="$c"
    [ -n "${d:-}" ] && snap="$d"
  else
    # No scenario, only start|target
    start="$a"
    target="$b"
    [ -n "${c:-}" ] && snap="$c"
  fi

  if [ -z "$start" ] || [ -z "$target" ]; then
    echo "[!] line $i invalid (need start and target): $line" >&2
    fail=$((fail+1))
    continue
  fi

  echo "[*] ($i) RUN: $start -> $target | snap=$snap | scenario=$scenario"

  # Build runner args
  args=()
  [ "$NO_ANIM" = "1" ] && args+=(--no-anim)
  args+=(--start "$start" --target "$target" --snap-mode "$snap")

  ADB_TCP_PORT="$ADB_TCP_PORT" \
  CFL_REMOTE_TMP_DIR="$CFL_REMOTE_TMP_DIR" \
  CFL_TMP_DIR="$CFL_TMP_DIR" \
  CFL_SCENARIO_SCRIPT="$scenario" \
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
