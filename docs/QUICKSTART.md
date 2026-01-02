# Quickstart

1. Install dependencies and copy scripts to `$HOME/cfl_watch` (artifacts go to `/sdcard/cfl_watch/{runs,logs}`):
```bash
pkg install -y git android-tools python
cd "$HOME/termux-scripts"  # or wherever you cloned
bash cfl_watch/tools/install_termux.sh
```

2. Start a run (default scenarios):
```bash
ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/runner.sh"
```

3. List scenarios:
```bash
ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/runner.sh" --list
```

4. Custom start/target without editing files:
```bash
ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/runner.sh" \
  --start "Esch-sur-Alzette" --target "Luxembourg" --snap-mode 3
```

5. Open the viewer on-device:
```bash
cd /sdcard/cfl_watch/runs/<latest>/viewers
python -m http.server 8000
# open http://127.0.0.1:8000 in mobile browser
# or: bash "$HOME/cfl_watch/runner.sh" --serve
```

6. Run self-check:
```bash
bash "$HOME/cfl_watch/tools/self_check.sh"
```
