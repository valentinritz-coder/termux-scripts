#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

CFL_CODE_DIR="${CFL_CODE_DIR:-${CFL_BASE_DIR:-~/cfl_watch}}"
START_TEXT="${START_TEXT:-LUXEMBOURG}"
TARGET_TEXT="${TARGET_TEXT:-ARLON}"
SNAP_MODE="${SNAP_MODE:-1}"

bash "$CFL_CODE_DIR/scenarios/scenario_trip.sh"
