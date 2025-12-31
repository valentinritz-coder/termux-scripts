cat > /sdcard/cfl_watch/adb_local.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SER="${ANDROID_SERIAL:-127.0.0.1:5555}"

start_adb_tcp() {
  su -c 'setprop service.adb.tcp.port 5555; setprop ctl.restart adbd' >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || true
  adb connect 127.0.0.1:5555 >/dev/null 2>&1 || true
  # if unauthorized, user must accept RSA prompt
  adb -s "$SER" get-state >/dev/null 2>&1 || true
}

stop_adb_tcp() {
  su -c 'setprop service.adb.tcp.port -1; setprop ctl.restart adbd' >/dev/null 2>&1 || true
}

case "${1:-}" in
  start) start_adb_tcp ;;
  stop)  stop_adb_tcp ;;
  *) echo "Usage: $0 {start|stop}" ; exit 1 ;;
esac
SH

chmod +x /sdcard/cfl_watch/adb_local.sh
