#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERIAL_DEFAULT="127.0.0.1:5555"
PORT="${ADB_TCP_PORT:-5555}"

die(){ echo "[!] $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

start_server() {
  have adb || die "adb introuvable (pkg install android-tools)"
  adb start-server >/dev/null 2>&1 || true
}

status() {
  have adb || die "adb introuvable"
  start_server
  echo "[*] adb devices -l:"
  adb devices -l || true
  echo
  echo "[*] netstat (si dispo) / ss (si dispo):"
  if have ss; then ss -ltnp 2>/dev/null | grep -E ":$PORT\b" || true
  elif have netstat; then netstat -ltnp 2>/dev/null | grep -E ":$PORT\b" || true
  else echo "(pas de ss/netstat)"; fi
}

start() {
  start_server

  # 1) Essaie d'activer adbd TCP côté Android (nécessite options dev / debug USB parfois)
  # Si ça échoue, on ne stoppe pas, mais on le verra au status.
  adb tcpip "$PORT" >/dev/null 2>&1 || true

  # 2) Connecte sur localhost (cas emulator/VM) et sur le serial préféré
  # IMPORTANT: on LOG les erreurs maintenant.
  echo "[*] adb connect $SERIAL_DEFAULT"
  adb connect "$SERIAL_DEFAULT" || true

  # 3) Affiche status
  status
}

stop() {
  have adb || exit 0
  start_server
  # On essaie de revenir en USB mode, best effort
  adb usb >/dev/null 2>&1 || true
  # Et on coupe le serveur côté Termux (optionnel)
  adb kill-server >/dev/null 2>&1 || true
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  *) echo "Usage: $0 {start|stop|status}" ; exit 2 ;;
esac
