#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}")"
CFL_BASE_DIR="$CFL_CODE_DIR"
. "$CFL_CODE_DIR/lib/common.sh"
. "$CFL_CODE_DIR/lib/snap.sh"

instruction="${LLM_INSTRUCTION:-}"
if [ -z "$instruction" ]; then
  die "LLM_INSTRUCTION is required. Example: LLM_INSTRUCTION='Recherche un trajet Luxembourg -> Arlon en train uniquement maintenant' bash $0"
fi

# keep runner redirection intact
if [ -z "${CFL_LOG_FILE:-}" ]; then
  attach_log "llm_tripplanner"
fi

ensure_dirs

: "${CFL_TMP_DIR:="$CFL_ARTIFACT_DIR/tmp"}"
export CFL_TMP_DIR

LLM_STEPS="${LLM_STEPS:-30}"
LLM_STEP_SLEEP="${LLM_STEP_SLEEP:-0.5}"
kill_switch="${LLM_KILL_SWITCH:-$CFL_ARTIFACT_DIR/STOP}"
dump_path="$CFL_TMP_DIR/live_dump.xml"
LLM_DEBUG_TAP="${LLM_DEBUG_TAP:-1}"

run_name="llm_tripplanner_$(safe_name "$instruction")"
snap_init "$run_name"

history_file="$SNAP_DIR/history.jsonl"
plan_file="$SNAP_DIR/trip_plan.json"

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
log "SNAP_DIR=$SNAP_DIR"
log "CFL_TMP_DIR=$CFL_TMP_DIR"
log "Kill switch: $kill_switch"
log "Steps: $LLM_STEPS, sleep=$LLM_STEP_SLEEP"
log "History: $history_file"

# Build trip plan once (heuristic by default; add --plan_llm if you want)
if [ ! -s "$plan_file" ]; then
  log "Build trip plan -> $plan_file"
  python "$CFL_CODE_DIR/tools/llm_explore.py" --emit_plan --instruction "$instruction" > "$plan_file"
  log "Trip plan: $(cat "$plan_file")"
fi

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

  log "Calling tripplanner LLM stepper"
  action_json="$(
    python "$CFL_CODE_DIR/tools/llm_explore.py" \
      --instruction "$instruction" \
      --xml "$dump_path" \
      --history_file "$history_file"
  )"

  log "Action JSON: $action_json"

  # extract fields for shell
  parsed="$(
    python - <<'PY' <<<"$action_json"
import json, sys
d=json.loads(sys.stdin.read())
def s(k):
  v=d.get(k,"")
  return "" if v is None else str(v)
out=[d.get("action",""), s("x"), s("y"), s("text"), s("keycode"), s("reason")]
print("|".join(out))
PY
  )"

  IFS="|" read -r act x y text keycode reason <<<"$parsed"
  act="${act//$'\r'/}"; x="${x//$'\r'/}"; y="${y//$'\r'/}"
  text="${text//$'\r'/}"; keycode="${keycode//$'\r'/}"
  reason="${reason//$'\r'/}"

  log "Decision: act=$act x=$x y=$y key=$keycode text='${text:0:40}' reason='${reason:0:120}'"

  case "$act" in
    tap)
      if [ -z "${x:-}" ] || [ -z "${y:-}" ]; then
        warn "tap coords empty -> abort"
        break
      fi

      if [ "$LLM_DEBUG_TAP" = "1" ]; then
        set +e
        serial_args=()
        if [ -n "${ANDROID_SERIAL:-}" ]; then
          serial_args=(-s "$ANDROID_SERIAL")
        fi
        adb "${serial_args[@]}" shell input tap "$x" "$y"
        rc=$?
        set -e
        log "adb tap rc=$rc"
        sleep_s 0.8
        snap "$(printf '%02d' "$step")_after_tap" "$SNAP_MODE"
      else
        maybe tap "$x" "$y"
      fi
      ;;
    type)
      log "Type: $text"
      maybe type_text "$text"
      ;;
    key)
      log "Key: $keycode"
      maybe key "$keycode"
      ;;
    done)
      log "Done."
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
