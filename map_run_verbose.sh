cat > /sdcard/cfl_watch/map_run_verbose.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PKG="de.hafas.android.cfl"
TS="$(date +%F_%H-%M-%S)"
LOG="/sdcard/cfl_watch/logs/map_verbose_${TS}.log"

mkdir -p /sdcard/cfl_watch/logs /sdcard/cfl_watch/map 2>/dev/null || true
exec >"$LOG" 2>&1

echo "=== START $(date) ==="
echo "LOG=$LOG"
echo "TERMUX_PATH=$PATH"
echo "UID=$(id || true)"
echo

# Focus helper (no su, absolute path)
focus_pkg() {
  /system/bin/dumpsys window windows 2>/dev/null \
    | grep -E 'mCurrentFocus|mFocusedApp' -m 2 || true
}

echo "[*] Before launch focus:"
focus_pkg
echo

echo "[*] Launching CFL with /system/bin/monkey (non-root)..."
/system/bin/monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 || echo "[!] monkey failed rc=$?"
sleep 1.5

echo
echo "[*] After launch focus:"
focus_pkg
echo

echo "[*] Running mapper (no-launch)..."
# Important: do NOT use & here. Let the process run while CFL is foreground.
bash -x /sdcard/cfl_watch/map.sh --no-launch "$@"

echo
echo "=== END $(date) ==="
SH

chmod +x /sdcard/cfl_watch/map_run_verbose.sh 2>/dev/null || true
