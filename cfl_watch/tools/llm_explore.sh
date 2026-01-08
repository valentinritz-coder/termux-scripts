#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

SNAP_MODE_SET=0
if [ "${SNAP_MODE+set}" = "set" ]; then
  SNAP_MODE_SET=1
fi

CFL_CODE_DIR="${CFL_CODE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CFL_CODE_DIR="$(expand_tilde_path "$CFL_CODE_DIR")"
CFL_BASE_DIR="${CFL_BASE_DIR:-$CFL_CODE_DIR}"

if [ -f "$CFL_CODE_DIR/env.sh" ]; then
  . "$CFL_CODE_DIR/env.sh"
fi
if [ -f "$CFL_CODE_DIR/env.local.sh" ]; then
  . "$CFL_CODE_DIR/env.local.sh"
fi

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}")"
CFL_BASE_DIR="${CFL_BASE_DIR:-$CFL_CODE_DIR}"
. "$CFL_CODE_DIR/lib/common.sh"
. "$CFL_CODE_DIR/lib/snap.sh"

if [ "$SNAP_MODE_SET" -eq 0 ]; then
  SNAP_MODE=3
fi

instruction="${1:-}"
if [ -z "$instruction" ]; then
  echo "Usage: $0 \"<instruction>\"" >&2
  exit 2
fi

attach_log "llm_explore"
ensure_dirs

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

log "Instruction: $instruction"
log "CFL_TMP_DIR=$CFL_TMP_DIR"
log "SNAP_DIR=$SNAP_DIR"

dump_path="$CFL_TMP_DIR/live_dump.xml"
kill_switch="/sdcard/cfl_watch/STOP"

maybe cfl_launch
sleep_s 1.0

for step in $(seq 1 30); do
  if inject test -f "$kill_switch" >/dev/null 2>&1; then
    warn "Kill switch detected ($kill_switch), stopping loop."
    break
  fi

  log "Step $step: dumping UI -> $dump_path"
  inject mkdir -p "$CFL_TMP_DIR" >/dev/null 2>&1 || true
  inject rm -f "$dump_path" >/dev/null 2>&1 || true
  inject uiautomator dump --compressed "$dump_path" 2>&1 | sed 's/^/[uia] /' >&2 || true

  if ! inject test -s "$dump_path" >/dev/null 2>&1; then
    warn "UI dump missing/empty, aborting."
    break
  fi

  snap "$(printf '%02d' "$step")" "$SNAP_MODE"

  log "Calling LLM explorer (step $step)"
  action_json="$(
    python "$CFL_CODE_DIR/tools/llm_explore.py" \
      --instruction "$instruction" \
      --xml "$dump_path"
  )"

  log "Action JSON: $action_json"

action="$(
  python - "$action_json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])

def val(k):
    v = d.get(k, "")
    return "" if v is None else str(v)

print("|".join([d.get("action",""), val("x"), val("y"), val("text"), val("keycode")]))
PY
)"



  IFS="|" read -r act x y text keycode <<<"$action"

  case "$act" in
    tap)
      log "LLM -> tap at $x,$y"
      maybe tap "$x" "$y"
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
      log "LLM -> done, stopping loop."
      break
      ;;
    *)
      warn "Unknown action: $act"
      break
      ;;
  esac

  sleep_s 0.5
done

log "llm_explore finished."
