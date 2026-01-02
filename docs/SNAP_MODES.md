# Snapshot modes

`SNAP_MODE` controls how snapshots are captured. Values:

- `0` – off (skip snapshots)
- `1` – PNG only
- `2` – XML only
- `3` – PNG + XML (default)

### Global vs per-step
- Set `SNAP_MODE` in the environment to define the default: `SNAP_MODE=1 bash runner.sh`.
- Override per step inside scenarios: `snap "tag" 2` to force XML-only for that call.

### Behavior
- Snapshots are stored under `/sdcard/cfl_watch/runs/<timestamp>_<scenario>/`.
- Viewer generation is resilient: it lists every step even if only PNG or only XML exists.
- On failures, scenarios attempt to build the viewer automatically when `SNAP_DIR` exists.
