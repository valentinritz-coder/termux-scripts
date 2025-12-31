cat > /sdcard/cfl_watch/map_run.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PKG="de.hafas.android.cfl"
TS="$(date +%F_%H-%M-%S)"
LOG="/sdcard/cfl_watch/logs/map_${TS}.log"

mkdir -p /sdcard/cfl_watch/logs /sdcard/cfl_watch/map 2>/dev/null || true
exec >"$LOG" 2>&1

run_root() {
  su -c "PATH=/system/bin:/system/xbin:/vendor/bin:\$PATH; $1"
}

echo "=== START $(date) ==="
echo "LOG=$LOG"

echo "[*] Launch CFL (root monkey)"
run_root "/system/bin/monkey -p $PKG -c android.intent.category.LAUNCHER 1" || true
sleep 1.5

echo "[*] Focus check (best effort)"
run_root "/system/bin/dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' -m 1" || true

echo "[*] Run mapper"
bash -x /sdcard/cfl_watch/map.sh --no-launch "$@"

echo "=== END $(date) ==="
SH

chmod +x /sdcard/cfl_watch/map_run.sh 2>/dev/null || true
