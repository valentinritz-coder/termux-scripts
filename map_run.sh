cat > /sdcard/cfl_watch/map_run.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PKG="de.hafas.android.cfl"

run_root() {
  if command -v su >/dev/null 2>&1; then su -c "$1"; else sh -c "$1"; fi
}

focus_pkg() {
  run_root "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp' -m 1" 2>/dev/null \
    | sed -n 's/.* \([a-zA-Z0-9_.]\+\)\/.*/\1/p' | head -n 1
}

bring_to_front() {
  # monkey is usually enough to foreground the app
  run_root "monkey -p '$PKG' -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1 || true
}

mkdir -p /sdcard/cfl_watch/map /sdcard/cfl_watch/logs 2>/dev/null || true

echo "[*] Launching $PKG ..."
for i in 1 2 3; do
  bring_to_front
  sleep 1.2
  f="$(focus_pkg || true)"
  echo "[*] Focus after launch try#$i: ${f:-?}"
  if [ "$f" = "$PKG" ]; then
    break
  fi
done

# Run mapper (it will only capture what is foreground)
exec bash /sdcard/cfl_watch/map.sh --no-launch "$@"
SH

chmod +x /sdcard/cfl_watch/map_run.sh 2>/dev/null || true
