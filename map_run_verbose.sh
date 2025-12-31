cat > /sdcard/cfl_watch/map_run_verbose.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PKG="de.hafas.android.cfl"
TS="$(date +%F_%H-%M-%S)"
LOG="/sdcard/cfl_watch/logs/map_verbose_${TS}.log"

# IMPORTANT: add system paths so /system/bin/monkey can find app_process
export PATH="/system/bin:/system/xbin:/vendor/bin:$PATH"

mkdir -p /sdcard/cfl_watch/logs /sdcard/cfl_watch/map 2>/dev/null || true
exec >"$LOG" 2>&1

echo "=== START $(date) ==="
echo "LOG=$LOG"
echo "PATH=$PATH"
echo "UID=$(id || true)"
echo

focus_line() {
  /system/bin/dumpsys activity activities 2>/dev/null | grep -E 'mResumedActivity|topResumedActivity' -m 1 || true
}

launch_cfl() {
  echo "[*] Launching CFL..."
  # 1) Try monkey (now PATH includes /system/bin so app_process is found)
  if /system/bin/monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
    echo "[+] monkey launch OK"
    return 0
  fi
  echo "[!] monkey failed, trying direct app_process..."

  # 2) Fallback: run Monkey via app_process directly (bypasses /system/bin/monkey script)
  local AP="/system/bin/app_process"
  [ -x /system/bin/app_process64 ] && AP="/system/bin/app_process64"

  CLASSPATH=/system/framework/monkey.jar "$AP" /system/bin com.android.commands.monkey.Monkey \
    -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 \
    && echo "[+] app_process monkey launch OK" && return 0

  echo "[!] launch failed"
  return 1
}

echo "[*] Before launch focus:"
focus_line
echo

launch_cfl || true
sleep 1.5

echo
echo "[*] After launch focus:"
focus_line
echo

echo "[*] Running mapper (no-launch)..."
bash -x /sdcard/cfl_watch/map.sh --no-launch "$@"

echo
echo "=== END $(date) ==="
SH

chmod +x /sdcard/cfl_watch/map_run_verbose.sh 2>/dev/null || true
