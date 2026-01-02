# Architecture overview

- **runner.sh** – Orchestrates scenarios, starts local ADB TCP (root), force-stops the CFL app between runs, and summarizes artifacts.
- **lib/**
  - `common.sh` – shared defaults, logging, path helpers, ADB wrappers.
  - `adb_local.sh` – start/stop/status for ADB over TCP on the device.
  - `snap.sh` – snapshot helpers with global/per-step `SNAP_MODE`.
  - `viewer.sh` – builds HTML viewers tolerant of missing PNG/XML.
- **scenarios/**
  - `scenario_trip.sh` – parameterized trip flow using shared helpers.
  - `scenario_trip_lux_arlon.sh` – thin wrapper example.
- **tools/**
  - `install_termux.sh` – install deps, copy scripts to `~/cfl_watch`, create `/sdcard/cfl_watch/{runs,logs}` shims, fix CRLF + permissions.
  - `self_check.sh` – light diagnostics (adb, python, device reachability).
  - `fix_perms_and_crlf.sh` – normalize files if edited off-device.
- **/sdcard/cfl_watch/runs/** – per-run artifacts (PNG/XML + viewers).
- **/sdcard/cfl_watch/logs/** – stdout/stderr logs from runner + tools.
- **sh/** – legacy shims preserved for backward compatibility; they forward to the new layout.

### Paths and env defaults
- `CFL_CODE_DIR` (default `~/cfl_watch`) hosts the scripts and executes everything.
- `CFL_ARTIFACT_DIR` (default `/sdcard/cfl_watch`) holds artifacts: `CFL_RUNS_DIR=$CFL_ARTIFACT_DIR/runs`, `CFL_LOG_DIR=$CFL_ARTIFACT_DIR/logs`.
- `CFL_TMP_DIR` defaults to `$CFL_CODE_DIR/tmp` for fast local scratch files.

### Data flow
1. `runner.sh` starts local ADB TCP via `lib/adb_local.sh` and exports `ANDROID_SERIAL`.
2. Each scenario calls `snap_init` (from `lib/snap.sh`) to open a run directory, executes UI actions, and calls `snap` with per-step overrides.
3. On failure (and when snapshots exist), scenarios trigger `lib/viewer.sh` to build HTML viewers.
4. Users can serve viewers on-device with `python -m http.server` from the run’s `viewers/` directory.
