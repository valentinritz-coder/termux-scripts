#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Smoke scenario: print env values passed by runner.
# Env: START_TEXT, TARGET_TEXT, VIA_TEXT (optional)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

CFL_CODE_DIR="${CFL_CODE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CFL_CODE_DIR="$(expand_tilde_path "$CFL_CODE_DIR")"
CFL_BASE_DIR="${CFL_BASE_DIR:-$CFL_CODE_DIR}"

. "$CFL_CODE_DIR/lib/common.sh"

START_TEXT="${START_TEXT:-}"
TARGET_TEXT="${TARGET_TEXT:-}"
VIA_TEXT="${VIA_TEXT:-}"

log "Smoke env: START_TEXT='$START_TEXT' TARGET_TEXT='$TARGET_TEXT' VIA_TEXT='$VIA_TEXT'"
