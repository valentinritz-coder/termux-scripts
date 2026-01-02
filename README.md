# CFL Watch (Termux)

Automation scripts for the **CFL mobile app** designed to run **directly on an Android phone** inside **Termux**.

- **Code** lives in: `$HOME/cfl_watch`
- **Artifacts** (runs + logs + viewers) live in: `/sdcard/cfl_watch/{runs,logs}`
- Uses **ADB over TCP** (root required) and can capture snapshots (PNG/XML) + build HTML viewers.

> Important: do **not** rely on `~` inside variables. Use `$HOME`.
> If you see errors claiming `lib/common.sh` is missing under `cfl_watch`, that's the tilde trap.

---

## Requirements

- Termux installed
- Root available (`su` works in Termux)
- Packages:
  - `android-tools` (adb)
  - `python` (viewer server + scripts)

---

## Quickstart

### 0) Allow storage access (once)
```bash
termux-setup-storage
```

### 1) Clone or update the repo

#### Fresh clone (recommended path)
```bash
pkg install -y git
git clone https://github.com/valentinritz-coder/termux-scripts.git "$HOME/termux-scripts"
cd "$HOME/termux-scripts"
```

#### Update an existing clone (preferred over re-cloning)
```bash
cd "$HOME/termux-scripts"
git pull --rebase
```

#### If you insist on nuking everything (only if needed)
```bash
rm -rf "$HOME/termux-scripts"
git clone https://github.com/valentinritz-coder/termux-scripts.git "$HOME/termux-scripts"
cd "$HOME/termux-scripts"
```

> If you get: `fatal: destination path 'termux-scripts' already exists...`
> you are trying to clone into a non-empty directory. Use `git pull` or delete the folder.

---

### 2) Install into `$HOME/cfl_watch` + create `/sdcard/cfl_watch` artifacts + shims
Run this from inside the repo:
```bash
bash cfl_watch/tools/install_termux.sh
```

After install you should have:
- `$HOME/cfl_watch` (real code)
- `/sdcard/cfl_watch/runs` and `/sdcard/cfl_watch/logs` (artifacts)
- `/sdcard/cfl_watch/runner.sh` and `/sdcard/cfl_watch/console.sh` (shims)

---

### 3) Self-check
```bash
bash "$HOME/cfl_watch/tools/self_check.sh"
```

If dependencies are missing:
```bash
pkg install -y android-tools python
```

---

## Tilde gotcha (and canonical commands)

`~` inside variables is **not expanded by Bash**. Always prefer `$HOME` or absolute paths.

Canonical invocations:
```bash
ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/runner.sh" --check
ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/runner.sh"
```

Optional overrides (if you moved things):
```bash
CFL_CODE_DIR="$HOME/cfl_watch" CFL_ARTIFACT_DIR="/sdcard/cfl_watch" \
  ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/runner.sh" --list
```

---

### 4) Start local ADB TCP (root)
```bash
ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/lib/adb_local.sh" start
adb devices -l
```

Expected: you see `127.0.0.1:37099 device` (not offline).

---

### 5) Run scenarios

#### List bundled scenarios
```bash
ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/runner.sh" --list
```

#### Run default scenario list (fast screenshots only)
```bash
ADB_TCP_PORT=37099 SNAP_MODE=1 bash "$HOME/cfl_watch/runner.sh"
```

#### Full debug (PNG + XML)
```bash
ADB_TCP_PORT=37099 SNAP_MODE=3 bash "$HOME/cfl_watch/runner.sh"
```

#### Run one custom trip
```bash
ADB_TCP_PORT=37099 SNAP_MODE=3 bash "$HOME/cfl_watch/runner.sh" \
  --start "LUXEMBOURG" --target "ARLON"
```

---

## Viewers

### Print newest run directory
```bash
bash "$HOME/cfl_watch/runner.sh" --latest-run
```

### Serve latest viewer (auto-generate if missing)
```bash
bash "$HOME/cfl_watch/runner.sh" --serve
```

Manual way:
```bash
latest="$(bash "$HOME/cfl_watch/runner.sh" --latest-run)"
cd "$latest/viewers"
python -m http.server 8000
```

Then open on your phone:
- `http://127.0.0.1:8000`

---

## Snapshot modes

`SNAP_MODE` controls what `snap` captures:

- `0` = off
- `1` = PNG only (fast)
- `2` = XML only
- `3` = PNG + XML (best for debugging)

Per-step override is supported inside scenarios:
- `snap "tag" 2` forces XML-only for that step.

---

## Layout

### Code (Termux home)
```
$HOME/cfl_watch
├── runner.sh
├── lib/
│   ├── common.sh
│   ├── adb_local.sh
│   ├── snap.sh
│   └── viewer.sh
├── scenarios/
├── tools/
└── tmp/
```

### Artifacts (shared storage)
```
/sdcard/cfl_watch
├── runner.sh    # shim -> $HOME/cfl_watch/runner.sh
├── console.sh   # shim
├── runs/        # per-run artifacts
└── logs/        # runner logs
```

---

## Common env vars

- `ADB_TCP_PORT` (default `37099`)
- `ADB_HOST` (default `127.0.0.1`)
- `ANDROID_SERIAL` (default `${ADB_HOST}:${ADB_TCP_PORT}`)
- `SNAP_MODE` (0..3)
- Delays:
  - `DELAY_LAUNCH`, `DELAY_TAP`, `DELAY_TYPE`, `DELAY_PICK`, `DELAY_SEARCH`

---

## Troubleshooting

### `lib/common.sh` not found (tilde not expanded)
You hit the `~` expansion trap. Use `$HOME` or absolute paths.
Example:
```bash
ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/runner.sh" --check
```

### `tar: .: file changed as we read it`
You likely ran install while copying a directory onto itself (source == destination).
Always run:
- from the repo: `$HOME/termux-scripts`
- installing to: `$HOME/cfl_watch`

### Selectors not found / scenario fails early
Run with full debug:
```bash
ADB_TCP_PORT=37099 SNAP_MODE=3 bash "$HOME/cfl_watch/runner.sh" --start "LUXEMBOURG" --target "ARLON"
```
Then inspect the viewer to adjust selectors to the real UI state.

### Device not reachable in self-check
Start ADB TCP first:
```bash
ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/lib/adb_local.sh" start
adb devices -l
```

---

## Notes

- Root is required for enabling ADB TCP (via `setprop service.adb.tcp.port` + restarting `adbd`).
- Keeping artifacts on `/sdcard` makes it easy to serve viewers (`python -m http.server`) and retrieve files.

## Quick verification
- `rg "~/cfl_watch"` inside the repo should return nothing (defaults now use `$HOME`).
- `bash "$HOME/cfl_watch/tools/self_check.sh"` works without `CFL_BASE_DIR`.
- `bash "$HOME/cfl_watch/runner.sh" --list` works without `CFL_BASE_DIR`.
- `CFL_CODE_DIR=~/cfl_watch bash "$HOME/cfl_watch/runner.sh" --list` still works because tilde normalization is built in.
