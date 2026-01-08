#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFL_CODE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CFL_SCENARIO_SCRIPT="$CFL_CODE_DIR/scenarios/smoke_env.sh" \
CFL_DRY_RUN=1 \
bash "$CFL_CODE_DIR/runner.sh" --dry-run \
  --start "LUXEMBOURG" \
  --via "BETTEMBOURG" \
  --target "ARLON" \
  --snap-mode 3
