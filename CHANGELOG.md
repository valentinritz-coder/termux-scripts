# Changelog

## Unreleased
- Fix tilde expansion in defaults; code runs from `$HOME/cfl_watch` while artifacts live under `/sdcard/cfl_watch/{runs,logs}` with configurable env vars.
- Updated installer to copy code to Termux home, create sdcard runs/logs, and drop forwarding shims in `/sdcard/cfl_watch`.
- Snapshot pipeline continues to honor `SNAP_MODE` (0-3) with per-step overrides and resilient viewer generation in the sdcard run folders.
- Runner exposes helper options for the latest run / viewer serving and force-stops CFL between scenarios.
- Legacy `sh/` entrypoints preserved as shims.
