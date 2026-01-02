#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-5555}"
SERIAL="${ADB_SERIAL:-$HOST:$PORT}"
SET_DEFAULT_SERIAL="${ADB_SET_DEFAULT_SERIAL:-1}"  # 1=export ANDROID_SERIAL

die(){ echo "[!] $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

require() {
  have adb || die "adb introuvable. Fais: pkg install android-tools"
  have su  || die "su introuvable. Root Magisk OK?"
}

adb_server_start() {
  adb start-server >/dev/null 2>&1 || true
}

adbd_restart() {
  # stop/start marche le plus souvent (ctl.restart parfois bloqué)
  su -c 'stop adbd; start adbd' >/dev/null 2>&1 || su -c 'setprop ctl.restart adbd' >/dev/null 2>&1 || true
}

wait_adbd_running() {
  # attend max ~10s
  for _ in $(seq 1 50); do
    state="$(su -c 'getprop init.svc.adbd' 2>/dev/null | tr -d '\r' || true)"
    [[ "$state" == "running" ]] && return 0
    sleep 0.2
  done
  return 1
}

show_status() {
  echo "[*] getprop:"
  su -c "getprop service.adb.tcp.port; getprop init.svc.adbd" || true
  echo
  echo "[*] adb devices -l:"
  adb devices -l || true
}

connect_retry() {
  # Retente plusieurs fois, le temps que adbd écoute réellement
  for _ in $(seq 1 8); do
    out="$(adb connect "$SERIAL" 2>&1 || true)"
    echo "[*] $out"
    echo "$out" | grep -qiE 'connected to|already connected' && return 0
    sleep 0.4
  done
  return 1
}

start() {
  require
  adb_server_start

  echo "[*] Activation ADB TCP sur ${SERIAL} (root)"
  su -c "setprop service.adb.tcp.port ${PORT}" >/dev/null 2>&1 || die "Impossible de setprop service.adb.tcp.port"

  echo "[*] Redémarrage adbd"
  adbd_restart

  echo "[*] Attente adbd=running"
  wait_adbd_running || echo "[!] adbd n'est pas repassé 'running' (on tente quand même)."

  # Repart propre côté serveur ADB Termux
  adb kill-server >/dev/null 2>&1 || true
  adb_server_start

  echo "[*] adb connect (retry)"
  connect_retry || die "Connexion ADB échouée (Connection refused). adbd n'écoute pas encore ou ROM bloque."

  # Si offline, on force un reconnect
  if adb devices | awk 'NR>1 && $1=="'"$SERIAL"'" {print $2}' | grep -qi offline; then
    echo "[!] Device offline, reconnect..."
    adb disconnect "$SERIAL" >/dev/null 2>&1 || true
    sleep 0.4
    connect_retry || die "Toujours offline après reconnect."
  fi

  if [[ "${SET_DEFAULT_SERIAL}" == "1" ]]; then
    export ANDROID_SERIAL="${SERIAL}"
    echo "[*] ANDROID_SERIAL fixé à ${ANDROID_SERIAL}"
  fi

  show_status
}

stop() {
  require
  adb_server_start

  echo "[*] Désactivation ADB TCP (service.adb.tcp.port=-1) + restart adbd"
  su -c 'setprop service.adb.tcp.port -1' >/dev/null 2>&1 || true
  adbd_restart
  wait_adbd_running >/dev/null 2>&1 || true

  echo "[*] adb disconnect ${SERIAL}"
  adb disconnect "${SERIAL}" >/dev/null 2>&1 || true

  adb devices -l || true
}

status() {
  require
  adb_server_start
  show_status
}

case "${1:-}" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  *) echo "Usage: $0 {start|stop|status}"
     echo "Env: ADB_TCP_PORT=5555 ADB_HOST=127.0.0.1 ADB_SERIAL=127.0.0.1:5555 ADB_SET_DEFAULT_SERIAL=1"
     exit 2 ;;
esac
