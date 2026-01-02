# CFL Watch (Termux)

Automation scripts for the CFL mobile app, optimized for running **directly on an Android phone** inside Termux. The toolkit handles ADB over TCP (root), captures UI snapshots (PNG/XML), and builds lightweight HTML viewers.

## Features
- Single entrypoint (`runner.sh`) to run one or multiple scenarios with per-step snapshots.
- Local ADB TCP bootstrap (`lib/adb_local.sh`) for rooted devices.
- Snapshot controls: `SNAP_MODE` 0=off, 1=png, 2=xml, 3=png+xml, with per-step overrides.
- Robust viewer generation that works with PNG-only or XML-only runs.
- Self-check and install helpers for fresh Termux sessions.

## Quickstart (Termux on device)
```bash
# 1) Clone or fetch this repo
pkg install -y git
git clone https://github.com/valentinritz-coder/termux-scripts.git
cd termux-scripts

# 2) Install into /sdcard/cfl_watch (installs deps + fixes perms)
bash cfl_watch/tools/install_termux.sh

# 3) Run built-in scenarios
ADB_TCP_PORT=37099 bash /sdcard/cfl_watch/runner.sh --list
ADB_TCP_PORT=37099 bash /sdcard/cfl_watch/runner.sh

# 4) Run a custom trip
ADB_TCP_PORT=37099 START_TEXT="Esch-sur-Alzette" TARGET_TEXT="Luxembourg" SNAP_MODE=3 \
  bash /sdcard/cfl_watch/runner.sh --start "Esch-sur-Alzette" --target "Luxembourg"
```

## Snapshot modes
- `SNAP_MODE=0` – off
- `SNAP_MODE=1` – PNG only
- `SNAP_MODE=2` – XML only
- `SNAP_MODE=3` – PNG+XML (default)

Any call to `snap "tag" 2` overrides the mode for that step.

## Viewers
After a run, open the viewer on-device:
```bash
cd /sdcard/cfl_watch/runs/<latest>/viewers
python -m http.server 8000
# then open http://127.0.0.1:8000 in a mobile browser
```

## Maintenance / tools
- `cfl_watch/tools/install_termux.sh` – install deps, copy files, fix CRLF, chmod.
- `cfl_watch/tools/self_check.sh` – verify adb, python, device reachability.
- `cfl_watch/tools/fix_perms_and_crlf.sh` – normalize files if you edit on Windows.

## Layout
```
/ sdcard / cfl_watch
├── runner.sh                # entrypoint
├── console.sh               # shim to runner
├── lib/                     # shared helpers
├── scenarios/               # scenario scripts
├── tools/                   # install + checks
├── runs/                    # per-run artifacts
└── logs/                    # stdout/stderr logs
```

## Upgrade notes
- Legacy entrypoints under `sh/` remain as shims and call the new layout.
- `snap.sh` now lives in `lib/snap.sh`; it honors per-step overrides and `SNAP_MODE` 0-3.
- `post_run_viewers.sh` has been replaced by `lib/viewer.sh` (works when PNG or XML is missing).

## Troubleshooting
See `docs/TROUBLESHOOTING.md` for common Termux + ADB issues and viewer tips.



1) Vérifie que tu es au bon endroit

Dans Termux:

ls -la /sdcard/cfl_watch
ls -la /sdcard/cfl_watch/lib
ls -la /sdcard/cfl_watch/scenarios
ls -la /sdcard/cfl_watch/tools


Tu dois voir runner.sh, lib/adb_local.sh, lib/snap.sh, tools/self_check.sh, etc.

2) Fix permissions + CRLF (au cas où)

Si tu as édité depuis Windows/OneDrive ou autre enfer:

bash /sdcard/cfl_watch/tools/fix_perms_and_crlf.sh /sdcard/cfl_watch

3) Self-check (ça évite 80% des “ça marche pas”)
bash /sdcard/cfl_watch/tools/self_check.sh


Si ça te dit que adb ou python manque:

pkg install -y android-tools python

4) Démarre ADB local (root + TCP)

Tu utilises déjà le port 37099, donc:

ADB_TCP_PORT=37099 bash /sdcard/cfl_watch/lib/adb_local.sh start


Puis vérifie que ton device est bien visible:

adb devices -l


Tu dois voir 127.0.0.1:37099 device (pas offline).

5) Lance un run “léger” pour valider (snap rapide)

Je te conseille d’abord PNG only (plus rapide que PNG+XML), ça te donne des screenshots pour débug visuellement.

ADB_TCP_PORT=37099 SNAP_MODE=1 bash /sdcard/cfl_watch/runner.sh


Si tu veux le mode full debug (plus lent):

ADB_TCP_PORT=37099 SNAP_MODE=3 bash /sdcard/cfl_watch/runner.sh

6) Ouvre le viewer du dernier run

Trouve le dernier dossier run:

ls -1dt /sdcard/cfl_watch/runs/* | head -n 1


Puis:

cd "$(ls -1dt /sdcard/cfl_watch/runs/* | head -n 1)/viewers"
python -m http.server 8000


Ouvre ensuite dans ton navigateur Android:
http://127.0.0.1:8000

7) Si tu veux lancer un seul trajet custom
ADB_TCP_PORT=37099 SNAP_MODE=1 bash /sdcard/cfl_watch/runner.sh --start "LUXEMBOURG" --target "ARLON"

8) Si ça foire: 2 checks utiles

Est-ce que CFL se lance manuellement sur le téléphone? (oui, banal, mais on a vu pire)

Est-ce que le focus est bon (l’app est vraiment au premier plan) ?

adb -s 127.0.0.1:37099 shell dumpsys window windows | grep -E "mCurrentFocus|mFocusedApp" | head
