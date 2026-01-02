# Changelog

## Unreleased
- Reorganized Termux-friendly layout under `/sdcard/cfl_watch` with shared `lib/` helpers.
- Added install + self-check tools for on-device bootstrap.
- Snapshot pipeline now honors `SNAP_MODE` (0-3) with per-step overrides and resilient viewer generation.
- Runner force-stops CFL between scenarios and surfaces artifact locations.
- Legacy `sh/` entrypoints preserved as shims.
