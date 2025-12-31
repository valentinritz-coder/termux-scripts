cat > /sdcard/cfl_watch/map_run.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PKG="de.hafas.android.cfl"

# Resolve launcher activity
COMP=$(/system/bin/cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$PKG" 2>/dev/null | tail -n 1)
echo "[*] COMP=$COMP"

# Launch (shell first, root fallback)
if [ -n "$COMP" ] && echo "$COMP" | grep -q '/'; then
  /system/bin/am start -W --user 0 -n "$COMP" >/dev/null 2>&1 \
    || su -c "/system/bin/am start -W --user 0 -n '$COMP'" >/dev/null 2>&1
else
  monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 \
    || su -c "monkey -p '$PKG' -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1
fi

sleep 1.5

# Run mapping without launching again
bash /sdcard/cfl_watch/map.sh --no-launch "$@"
SH

chmod +x /sdcard/cfl_watch/map_run.sh 2>/dev/null || true
