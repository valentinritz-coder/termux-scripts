#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}")"
CFL_BASE_DIR="$CFL_CODE_DIR"
. "$CFL_CODE_DIR/lib/common.sh"
. "$CFL_CODE_DIR/lib/snap.sh"

# Instruction: runner ne passe pas d'args -> env obligatoire
instruction="${LLM_INSTRUCTION:-}"
if [ -z "$instruction" ] && [ -z "${LLM_TRIP_JSON:-}" ]; then
  die "LLM_INSTRUCTION or LLM_TRIP_JSON is required.
Example:
  export LLM_INSTRUCTION='Recherche un trajet entre Luxembourg et Arlon en train uniquement pour maintenant.'
  bash $0"
fi

# Logs only if standalone (runner already redirects)
if [ -z "${CFL_LOG_FILE:-}" ]; then
  attach_log "llm_tripplanner"
fi

ensure_dirs

# Deps python (requests)
python - <<'PY' >/dev/null 2>&1 || die "Python dependency missing: requests (run: pip install requests)"
import requests  # noqa
PY

# If LLM base URL missing, warn (fallback parser still works)
if [ -z "${OPENAI_BASE_URL:-}" ] && [ -z "${LLM_TRIP_JSON:-}" ]; then
  warn "OPENAI_BASE_URL is not set. Will rely on fallback parsing only."
fi

TRIP_JSON="${LLM_TRIP_JSON:-}"
if [ -z "$TRIP_JSON" ]; then
  log "Parsing instruction to TripRequest JSON (LLM as parser)"
  TRIP_JSON="$(
    python "$CFL_CODE_DIR/tools/llm_trip_request.py" \
      --instruction "$instruction" \
      --model "${LLM_MODEL:-local-model}"
  )"
fi

log "TripRequest: $TRIP_JSON"

# Extract fields (and uppercase)
read_vars="$(
  python - <<'PY' "$TRIP_JSON"
import json, sys
req = json.loads(sys.argv[1])
start = (req.get("start","") or "").strip().upper()
dest  = (req.get("destination","") or "").strip().upper()
when  = (req.get("when","now") or "now").strip()
rail  = bool(req.get("rail_only", True))
print(start)
print(dest)
print(when)
print("1" if rail else "0")
PY
)"

START_TEXT="$(printf '%s\n' "$read_vars" | sed -n '1p')"
TARGET_TEXT="$(printf '%s\n' "$read_vars" | sed -n '2p')"
WHEN_TEXT="$(printf '%s\n' "$read_vars" | sed -n '3p')"
RAIL_ONLY="$(printf '%s\n' "$read_vars" | sed -n '4p')"

if [ -z "$START_TEXT" ] || [ -z "$TARGET_TEXT" ]; then
  die "TripRequest missing start/destination. Got: $TRIP_JSON"
fi

if [ "$WHEN_TEXT" != "now" ]; then
  warn "WHEN != now is not wired to UI yet (still runs default 'Dep now'). when=$WHEN_TEXT"
fi

if [ "$RAIL_ONLY" = "1" ]; then
  log "rail_only requested (filtering is UI-specific; not enforced yet unless you add the settings steps)."
fi

# Now run your deterministic scenario (the reliable part)
export START_TEXT
export TARGET_TEXT

# keep user SNAP_MODE if set, else default
export SNAP_MODE="${SNAP_MODE:-1}"

log "Executing deterministic scenario_trip.sh with START_TEXT=$START_TEXT TARGET_TEXT=$TARGET_TEXT"
bash "$CFL_CODE_DIR/scenarios/scenario_trip.sh"
