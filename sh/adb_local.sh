#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Defaults (changeable via env vars)
HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-37099}"        # <-- défaut: 37099 (évite la zone “emulator ports”)
SERIAL="${ADB_SERIAL:-$HOST:$PORT}"  # ex: 127.0.0.1:37099

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
  # stop/start est généralement le plus fiable
  su -c 'stop adbd; start adbd' >/dev/null 2>&1 || su -c 'setprop ctl.restart adbd' >/dev/null 2>&1 || true
}

wait_adbd_running() {
  # max ~10s
  for _ in $(seq 1 50); do
    state="$(su -c 'getprop init.svc.adbd' 2>/dev/null | tr -d '\r' || true)"
    [[ "$state" == "running" ]] && return 0
    sleep 0.2
  done
  return 1
}

connect_retry() {
  for _ in $(seq 1 10); do
    out="$(adb connect "$SERIAL" 2>&1 || true)"
    echo "[*] $out"
    echo "$out" | grep -qiE 'connected to|already connected' && return 0
    sleep 0.4
  done
  return 1
}

device_state() {
  # Retourne: device / offline / (vide)
  adb devices | awk -v s="$SERIAL" 'NR>1 && $1==s {print $2}'
}

show_status() {
  echo "[*] getprop:"
  su -c "getprop service.adb.tcp.port; getprop init.svc.adbd" || true
  echo
  echo "[*] adb devices -l:"
  adb devices -l || true
  echo
  echo "[*] Pour éviter 'more than one device':"
  echo "    adb -s $SERIAL shell <commande>"
  echo "    ou dans TON terminal: export ANDROID_SERIAL=$SERIAL"
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

  echo "[*] adb connect (retry) -> ${SERIAL}"
  connect_retry || die "Connexion ADB échouée (Connection refused)."

  # Si offline, on force un reconnect
  if [[ "$(device_state || true)" == "offline" ]]; then
    echo "[!] Device offline, reconnect..."
    adb disconnect "$SERIAL" >/dev/null 2>&1 || true
    sleep 0.5
    connect_retry || die "Toujours offline après reconnect."
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

  # Nettoyage des devices fantômes
  adb kill-server >/dev/null 2>&1 || true

  echo "[*] adb devices -l:"
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
  *)
    echo "Usage: $0 {start|stop|status}"
    echo "Env vars: ADB_TCP_PORT=37099 ADB_HOST=127.0.0.1 ADB_SERIAL=127.0.0.1:37099"
    exit 2
    ;;
esac
