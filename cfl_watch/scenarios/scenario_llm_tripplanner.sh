#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}")"
CFL_BASE_DIR="$CFL_CODE_DIR"
. "$CFL_CODE_DIR/lib/common.sh"
. "$CFL_CODE_DIR/lib/snap.sh"

. "$CFL_CODE_DIR/lib/snap.sh"
. "$CFL_CODE_DIR/lib/common.sh"

instruction="${LLM_INSTRUCTION:-}"
if [ -z "$instruction" ]; then
  die "LLM_INSTRUCTION is required. Example: LLM_INSTRUCTION='Luxembourg -> Arlon, train only, now' bash $0"
fi

# logging (standalone)
if [ -z "${CFL_LOG_FILE:-}" ]; then
  attach_log "llm_tripplanner"
fi

ensure_dirs

: "${CFL_TMP_DIR:="$CFL_ARTIFACT_DIR/tmp"}"
export CFL_TMP_DIR

LLM_STEPS="${LLM_STEPS:-25}"
LLM_STEP_SLEEP="${LLM_STEP_SLEEP:-0.5}"
kill_switch="${LLM_KILL_SWITCH:-$CFL_ARTIFACT_DIR/STOP}"
dump_path="$CFL_TMP_DIR/live_dump.xml"
SNAP_MODE="${SNAP_MODE:-3}"

# LLM endpoint/model
export OPENAI_BASE_URL="${OPENAI_BASE_URL:-http://127.0.0.1:8001}"
export LLM_MODEL="${LLM_MODEL:-local-model}"
export LLM_MAX_TOKENS="${LLM_MAX_TOKENS:-200}"
export LLM_TEMPERATURE="${LLM_TEMPERATURE:-0}"

run_name="llm_tripplanner_$(safe_name "$instruction")"
snap_init "$run_name"

# history per run (kept inside SNAP_DIR)
export LLM_HISTORY_FILE="${LLM_HISTORY_FILE:-$SNAP_DIR/history.jsonl}"
export LLM_HISTORY_LIMIT="${LLM_HISTORY_LIMIT:-10}"

finish(){
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    warn "llm_tripplanner FAILED (rc=$rc) -> viewer"
    "$CFL_CODE_DIR/lib/viewer.sh" "$SNAP_DIR" >/dev/null 2>&1 || true
    log "Viewer: $SNAP_DIR/viewers/index.html"
  fi
  exit "$rc"
}
trap finish EXIT

# deps
python - <<'PY' >/dev/null 2>&1 || die "Python dependency missing: requests (run: pip install requests)"
import requests  # noqa
PY

dump_ui(){
  inject mkdir -p "$CFL_TMP_DIR" >/dev/null 2>&1 || true
  inject rm -f "$dump_path" >/dev/null 2>&1 || true
  inject uiautomator dump --compressed "$dump_path" 2>&1 | sed 's/^/[uia] /' >&2 || true

  if ! inject test -s "$dump_path" >/dev/null 2>&1; then
    warn "UI dump missing/empty: $dump_path"
    return 1
  fi

  if ! grep -q "<hierarchy" "$dump_path" >/dev/null 2>&1; then
    warn "UI dump invalid (no <hierarchy): $dump_path"
    return 1
  fi
  return 0
}

log "Instruction: $instruction"
log "OPENAI_BASE_URL=$OPENAI_BASE_URL"
log "LLM_MODEL=$LLM_MODEL"
log "CFL_TMP_DIR=$CFL_TMP_DIR"
log "SNAP_DIR=$SNAP_DIR"
log "History: $LLM_HISTORY_FILE"
log "Kill switch: $kill_switch"
log "Steps: $LLM_STEPS, sleep=$LLM_STEP_SLEEP"
log "SNAP_MODE=$SNAP_MODE"

# runner should have launched the app already, but keep a safety net
maybe cfl_launch
sleep_s 0.8

dump_ui || true
snap "00_state" "$SNAP_MODE"

for step in $(seq 1 "$LLM_STEPS"); do
  if inject test -f "$kill_switch" >/dev/null 2>&1; then
    warn "Kill switch detected ($kill_switch), stopping."
    break
  fi

  log "Step $step: dump UI"
  if ! dump_ui; then
    warn "Abort: dump UI failed"
    break
  fi

  snap "$(printf '%02d' "$step")" "$SNAP_MODE"

  log "Calling llm_explore.py (tripplanner mode)"
  action_json="$(
    python "$CFL_CODE_DIR/tools/llm_explore.py" \
      --instruction "$instruction" \
      --xml "$dump_path"
  )"

  log "Action JSON: $action_json"

  # Extract fields (avoid jq dependency)
  action="$(
    python -c '
import json, sys
d=json.loads(sys.stdin.read())
def v(k):
    x=d.get(k,"")
    return "" if x is None else str(x)
print("|".join([v("action"), v("x"), v("y"), v("text"), v("keycode"), v("target_idx"), v("reason")]))
' <<<"$action_json"
  )"

  IFS="|" read -r act x y text keycode tidx reason <<<"$action"
  act="${act//$'\r'/}"; x="${x//$'\r'/}"; y="${y//$'\r'/}"
  text="${text//$'\r'/}"; keycode="${keycode//$'\r'/}"; tidx="${tidx//$'\r'/}"
  reason="${reason//$'\r'/}"

  case "$act" in
    tap)
      log "LLM -> tap tidx=$tidx x=$x y=$y reason=$reason"
      if [ -z "${x:-}" ] || [ -z "${y:-}" ]; then
        warn "tap coords empty -> abort"
        break
      fi
      maybe tap "$x" "$y"
      sleep_s 0.8
      snap "$(printf '%02d' "$step")_after_tap" "$SNAP_MODE"
      ;;
    type)
      log "LLM -> type: $text reason=$reason"
      maybe type_text "$text"
      ;;
    key)
      log "LLM -> keycode: $keycode reason=$reason"
      maybe key "$keycode"
      ;;
    done)
      log "LLM -> done reason=$reason"
      break
      ;;
    *)
      warn "Unknown action: $act"
      break
      ;;
  esac

  sleep_s "$LLM_STEP_SLEEP"
done

log "llm_tripplanner finished."
exit 0
