#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Manage local ADB over TCP (root required)
# Usage: ADB_TCP_PORT=37099 ADB_HOST=127.0.0.1 ./adb_local.sh {start|stop|status}

HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-37099}"
SERIAL="${ADB_SERIAL:-$HOST:$PORT}"

log(){ printf '[*] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[!!] %s\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

require(){
  have adb || die "adb introuvable (pkg install android-tools)"
  have su  || die "su introuvable (root Magisk?)"
}

adb_server_start(){ adb start-server >/dev/null 2>&1 || true; }

adbd_restart(){
  su -c 'stop adbd; start adbd' >/dev/null 2>&1 || su -c 'setprop ctl.restart adbd' >/dev/null 2>&1 || true
}

wait_adbd_running(){
  for _ in $(seq 1 50); do
    state="$(su -c 'getprop init.svc.adbd' 2>/dev/null | tr -d '\r' || true)"
    [[ "$state" == "running" ]] && return 0
    sleep 0.2
  done
  return 1
}

connect_retry(){
  for _ in $(seq 1 10); do
    out="$(adb connect "$SERIAL" 2>&1 || true)"
    log "$out"
    echo "$out" | grep -qiE 'connected to|already connected' && return 0
    sleep 0.4
  done
  return 1
}

device_state(){ adb devices | awk -v s="$SERIAL" 'NR>1 && $1==s {print $2}'; }

show_status(){
  log "getprop:"; su -c "getprop service.adb.tcp.port; getprop init.svc.adbd" || true
  log "adb devices -l:"; adb devices -l || true
  log "Pour éviter 'more than one device': export ANDROID_SERIAL=$SERIAL"
}

start(){
  require; adb_server_start
  log "Activation ADB TCP sur ${SERIAL} (root)"
  su -c "setprop service.adb.tcp.port ${PORT}" >/dev/null 2>&1 || die "Impossible de setprop service.adb.tcp.port"
  log "Redémarrage adbd"; adbd_restart
  log "Attente adbd=running"; wait_adbd_running || warn "adbd pas 'running' (on tente quand même)"
  adb kill-server >/dev/null 2>&1 || true; adb_server_start
  log "adb connect (retry) -> ${SERIAL}"; connect_retry || die "Connexion ADB échouée"
  if [[ "$(device_state || true)" == "offline" ]]; then
    warn "Device offline, reconnect"
    adb disconnect "$SERIAL" >/dev/null 2>&1 || true
    sleep 0.5
    connect_retry || die "Toujours offline"
  fi
  show_status
}

stop(){
  require; adb_server_start
  log "Désactivation ADB TCP (service.adb.tcp.port=-1) + restart adbd"
  su -c 'setprop service.adb.tcp.port -1' >/dev/null 2>&1 || true
  adbd_restart; wait_adbd_running >/dev/null 2>&1 || true
  log "adb disconnect ${SERIAL}"; adb disconnect "$SERIAL" >/dev/null 2>&1 || true
  adb kill-server >/dev/null 2>&1 || true
  log "adb devices -l:"; adb devices -l || true
}

status(){ require; adb_server_start; show_status; }

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  *) echo "Usage: $0 {start|stop|status}"; echo "Env: ADB_TCP_PORT=37099 ADB_HOST=127.0.0.1 ADB_SERIAL=127.0.0.1:37099"; exit 2 ;;
esac
