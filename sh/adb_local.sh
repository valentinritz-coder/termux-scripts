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
  have su  || die "su introuvable. Ton root Magisk est OK?"
}

adb_server_start() {
  adb start-server >/dev/null 2>&1 || true
}

adbd_restart() {
  # Certaines ROM acceptent ctl.restart, d'autres préfèrent stop/start
  if su -c 'setprop ctl.restart adbd' >/dev/null 2>&1; then
    return 0
  fi
  su -c 'stop adbd; start adbd' >/dev/null 2>&1 || true
}

port_listening() {
  if have ss; then
    ss -ltnp 2>/dev/null | grep -E ":${PORT}\b" >/dev/null 2>&1
  elif have netstat; then
    netstat -ltnp 2>/dev/null | grep -E ":${PORT}\b" >/dev/null 2>&1
  else
    # Pas de ss/netstat: on ne peut pas vérifier proprement, on “best effort”
    return 0
  fi
}

show_status() {
  echo "[*] getprop:"
  su -c "getprop service.adb.tcp.port; getprop init.svc.adbd" || true
  echo
  echo "[*] Port check (:${PORT}):"
  if have ss; then ss -ltnp 2>/dev/null | grep -E ":${PORT}\b" || true
  elif have netstat; then netstat -ltnp 2>/dev/null | grep -E ":${PORT}\b" || true
  else echo "(pas de ss/netstat)"; fi
  echo
  echo "[*] adb devices -l:"
  adb devices -l || true
}

start() {
  require
  adb_server_start

  echo "[*] Activation ADB TCP sur ${HOST}:${PORT} (root)"
  su -c "setprop service.adb.tcp.port ${PORT}" >/dev/null 2>&1 || die "Impossible de setprop service.adb.tcp.port"
  echo "[*] Redémarrage adbd"
  adbd_restart
  sleep 0.5

  # Vérif que la prop a bien pris
  cur="$(su -c 'getprop service.adb.tcp.port' 2>/dev/null || true)"
  [[ "$cur" == "$PORT" ]] || die "service.adb.tcp.port vaut '$cur' (attendu: $PORT)."

  # Vérif écoute
  if ! port_listening; then
    echo "[!] Rien n'écoute sur :${PORT} (ss/netstat). Je tente un restart adbd de plus."
    adbd_restart
    sleep 0.5
    port_listening || echo "[!] Toujours pas d'écoute détectée. On tente quand même adb connect."
  fi

  echo "[*] adb connect ${SERIAL}"
  adb connect "${SERIAL}" || die "adb connect a échoué (Connection refused = adbd n'écoute pas)."

  # Optionnel: éviter que adb choisisse l'autre pseudo-device (emulator-5554)
  if [[ "${SET_DEFAULT_SERIAL}" == "1" ]]; then
    export ANDROID_SERIAL="${SERIAL}"
    echo "[*] ANDROID_SERIAL fixé à ${ANDROID_SERIAL}"
  fi

  show_status
}

stop() {
  require
  adb_server_start

  echo "[*] Désactivation ADB TCP (service.adb.tcp.port = -1) + restart adbd"
  su -c 'setprop service.adb.tcp.port -1' >/dev/null 2>&1 || true
  adbd_restart
  sleep 0.3

  echo "[*] adb disconnect ${SERIAL}"
  adb disconnect "${SERIAL}" >/dev/null 2>&1 || true

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
  *) echo "Usage: $0 {start|stop|status}"
     echo "Env vars: ADB_TCP_PORT=5555 ADB_HOST=127.0.0.1 ADB_SERIAL=127.0.0.1:5555 ADB_SET_DEFAULT_SERIAL=1"
     exit 2 ;;
esac
