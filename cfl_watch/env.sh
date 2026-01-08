#!/data/data/com.termux/files/usr/bin/bash
# shellcheck shell=bash

# env.sh - Defaults for cfl_watch
# Usage:
#   source "$CFL_CODE_DIR/env.sh" 2>/dev/null || true
#   source "$CFL_CODE_DIR/env.local.sh" 2>/dev/null || true

# Base dirs
: "${CFL_CODE_DIR:=${CFL_BASE_DIR:-$HOME/cfl_watch}}"
: "${CFL_BASE_DIR:=$CFL_CODE_DIR}"
: "${CFL_ARTIFACT_DIR:=/sdcard/cfl_watch}"

# Device / adb
: "${ADB_TCP_PORT:=37099}"
: "${ADB_HOST:=127.0.0.1}"
: "${ANDROID_SERIAL:=${ADB_HOST}:${ADB_TCP_PORT}}"

# Temp dirs
: "${CFL_TMP_DIR:=$CFL_ARTIFACT_DIR/tmp}"
: "${CFL_REMOTE_TMP_DIR:=/data/local/tmp/cfl_watch}"

# Scenario selection (runner uses this)
: "${CFL_SCENARIO_SCRIPT:=$CFL_CODE_DIR/scenarios/trip_api.sh}"

# Snapshots
: "${SNAP_MODE:=1}"        # 0=off,1=png,2=xml,3=both
: "${CFL_DUMP_TIMING:=1}"  # logs dump timing

# Wait tuning (API/UI)
: "${WAIT_POLL:=0.0}"
: "${WAIT_SHORT:=20}"
: "${WAIT_LONG:=30}"

# Optional: dry-run mode
: "${CFL_DRY_RUN:=0}"
