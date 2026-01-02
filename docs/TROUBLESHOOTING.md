# Troubleshooting

## ADB TCP will not connect
- Ensure the device is rooted and `su` works inside Termux.
- Run `bash "$HOME/cfl_watch/lib/adb_local.sh" status` to see current TCP port.
- Try restarting ADB TCP: `ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/lib/adb_local.sh" start`.
- If you see `offline`, run `adb disconnect 127.0.0.1:37099` and retry.

## Viewer shows 0 pages
- Check that snapshots exist under `runs/<run>/`.
- Rebuild viewers manually: `bash "$HOME/cfl_watch/lib/viewer.sh" /sdcard/cfl_watch/runs/<run>`.
- PNG-only or XML-only runs are supported; the index still lists all steps.

## Snapshots missing
- Confirm `SNAP_MODE` is not `0` and that the scenario calls `snap` after `snap_init`.
- On slow devices, increase delays: `DELAY_LAUNCH=2 DELAY_SEARCH=1.5 ...` when calling `runner.sh`.

## App state issues between runs
- `runner.sh` force-stops the CFL app before and after each scenario. If you still see stale state, uninstall/reinstall the app or reboot.

## Termux permissions
- Termux must have storage permissions to write under `/sdcard/cfl_watch` (`termux-setup-storage`).
- Run `bash "$HOME/cfl_watch/tools/fix_perms_and_crlf.sh" "$HOME/cfl_watch"` if files were edited on Windows.

## Self-check
- Run `bash "$HOME/cfl_watch/tools/self_check.sh"` to verify adb/python and device reachability.
