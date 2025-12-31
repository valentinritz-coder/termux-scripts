cat > /sdcard/cfl_watch/map_run.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PKG="de.hafas.android.cfl"

run_root() {
  if command -v su >/dev/null 2>&1; then su -c "$1"; else sh -c "$1"; fi
}

get_focus_pkg() {
  run_root "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp' -m 1" 2>/dev/null \
    | sed -n 's/.* \([a-zA-Z0-9_.]\+\)\/.*/\1/p' | head -n 1
}

resolve_launcher() {
  # Try non-root cmd (can fail on some devices with binder transaction errors)
  local out
  out=$(/system/bin/cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$PKG" 2>/dev/null || true)
  echo "$out" | tail -n 1 | grep -q '/' && { echo "$out" | tail -n 1; return 0; }

  # Try root cmd
  out=$(run_root "/system/bin/cmd package resolve-activity --brief -c android.intent.category.LAUNCHER '$PKG' 2>/dev/null" || true)
  echo "$out" | tail -n 1 | grep -q '/' && { echo "$out" | tail -n 1; return 0; }

  echo ""
}

echo "[*] Launching $PKG ..."

COMP="$(resolve_launcher)"
if [ -n "$COMP" ]; then
  echo "[*] Using component: $COMP"
  /system/bin/am start -W --user 0 -n "$COMP" >/dev/null 2>&1 \
    || run_root "/system/bin/am start -W --user 0 -n '$COMP'" >/dev/null 2>&1 \
    || true
else
  echo "[*] resolve-activity failed -> fallback to monkey"
  monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 \
    || run_root "monkey -p '$PKG' -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1 \
    || true
fi

sleep 1.5

FOCUS="$(get_focus_pkg || true)"
echo "[*] Focus pkg: ${FOCUS:-?}"

# Ensure base out dir exists (idiot-proof)
mkdir -p /sdcard/cfl_watch/map 2>/dev/null || true

# Run mapper without launch
exec bash /sdcard/cfl_watch/map.sh --no-launch "$@"
SH

chmod +x /sdcard/cfl_watch/map_run.sh 2>/dev/null || true
