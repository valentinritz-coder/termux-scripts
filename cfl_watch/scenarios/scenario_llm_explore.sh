#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}")"
CFL_BASE_DIR="$CFL_CODE_DIR"
. "$CFL_CODE_DIR/lib/common.sh"
. "$CFL_CODE_DIR/lib/snap.sh"

# Instruction LLM: runner ne passe pas d'args -> env obligatoire
instruction="${LLM_INSTRUCTION:-}"
if [ -z "$instruction" ]; then
  die "LLM_INSTRUCTION is required (runner does not pass args). Example: LLM_INSTRUCTION='Ouvre CFL...' bash runner.sh --instruction '...'"
fi

# Ne pas casser la redirection du runner: attach_log seulement si standalone
if [ -z "${CFL_LOG_FILE:-}" ]; then
  attach_log "llm_explore"
fi

ensure_dirs

# IMPORTANT: dump uiautomator doit être dans un chemin accessible via adb shell
: "${CFL_TMP_DIR:="$CFL_ARTIFACT_DIR/tmp"}"
export CFL_TMP_DIR

# Tuning
LLM_STEPS="${LLM_STEPS:-30}"
LLM_STEP_SLEEP="${LLM_STEP_SLEEP:-0.5}"
kill_switch="${LLM_KILL_SWITCH:-$CFL_ARTIFACT_DIR/STOP}"
dump_path="$CFL_TMP_DIR/live_dump.xml"
LLM_DEBUG_TAP="${LLM_DEBUG_TAP:-1}"

run_name="llm_explore_$(safe_name "$instruction")"
snap_init "$run_name"

finish(){
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    warn "llm_explore FAILED (rc=$rc) -> viewer"
    "$CFL_CODE_DIR/lib/viewer.sh" "$SNAP_DIR" >/dev/null 2>&1 || true
    log "Viewer: $SNAP_DIR/viewers/index.html"
  fi
  exit "$rc"
}
trap finish EXIT

# Déps python (requests)
python - <<'PY' >/dev/null 2>&1 || die "Python dependency missing: requests (run: pip install requests)"
import requests  # noqa
PY

# Check endpoint
if [ -z "${OPENAI_BASE_URL:-}" ]; then
  warn "OPENAI_BASE_URL is not set. Example: export OPENAI_BASE_URL=http://127.0.0.1:8001"
fi

dump_ui(){
  inject mkdir -p "$CFL_TMP_DIR" >/dev/null 2>&1 || true
  inject rm -f "$dump_path" >/dev/null 2>&1 || true
  inject uiautomator dump --compressed "$dump_path" 2>&1 | sed 's/^/[uia] /' >&2 || true

  # présence + taille (côté device)
  if ! inject test -s "$dump_path" >/dev/null 2>&1; then
    warn "UI dump missing/empty: $dump_path"
    return 1
  fi

  # validation du contenu (côté Termux, car /sdcard est lisible localement)
  if ! grep -q "<hierarchy" "$dump_path" >/dev/null 2>&1; then
    warn "UI dump invalid (no <hierarchy): $dump_path"
    return 1
  fi

  return 0
}


log "Instruction: $instruction"
log "CFL_TMP_DIR=$CFL_TMP_DIR"
log "SNAP_DIR=$SNAP_DIR"
log "Kill switch: $kill_switch"
log "Steps: $LLM_STEPS, sleep=$LLM_STEP_SLEEP"

# Snapshot initial (runner a déjà launch l'app)
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

  log "Calling LLM explorer"
  action_json="$(
    python "$CFL_CODE_DIR/tools/llm_explore.py" \
      --instruction "$instruction" \
      --xml "$dump_path"
  )"

  log "Action JSON: $action_json"

  action="$(
    python -c '
import json, sys
d=json.loads(sys.stdin.read())
def val(k):
    v=d.get(k,"")
    return "" if v is None else str(v)
print("|".join([d.get("action",""), val("x"), val("y"), val("text"), val("keycode")]))
' <<<"$action_json"
  )"

  IFS="|" read -r act x y text keycode <<<"$action"
  act="${act//$'\r'/}"; x="${x//$'\r'/}"; y="${y//$'\r'/}"
  text="${text//$'\r'/}"; keycode="${keycode//$'\r'/}"

  case "$act" in
    tap)
      log "LLM -> tap $x,$y (debug=$LLM_DEBUG_TAP)"
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
      log "LLM -> type: $text"
      maybe type_text "$text"
      ;;
    key)
      log "LLM -> keycode: $keycode"
      maybe key "$keycode"
      ;;
    done)
      log "LLM -> done"
      break
      ;;
    *)
      warn "Unknown action: $act"
      break
      ;;
  esac

  sleep_s "$LLM_STEP_SLEEP"
done

log "llm_explore finished."
exit 0
