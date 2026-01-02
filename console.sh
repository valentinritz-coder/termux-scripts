#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# --- ADB local config (nouveau port) ---
HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-37099}"
SERIAL="${ADB_SERIAL:-$HOST:$PORT}"
export ANDROID_SERIAL="$SERIAL"

BASE="/sdcard/cfl_watch"

mkdir -p "$BASE"/{logs,map,tmp}

# Toujours essayer de stopper ADB local en sortant, même en cas d'erreur
cleanup() {
  # best effort
  ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Si tu as le script d'update (optionnel)
[ -x "$BASE/update_from_github.sh" ] && bash "$BASE/update_from_github.sh" >/dev/null 2>&1 || true

# 1) Start ADB local (force le port 37099)
ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" start

# 2) Ouvre CFL (best effort)
adb shell monkey -p de.hafas.android.cfl -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 2

# 3) Scénario: remplir start/destination + search (adapte les stations)
bash "$BASE/scenario_trip.sh" "Luxembourg" "Arlon" >/dev/null 2>&1 || true

# 4) Mapping depuis l'écran courant (ne relance pas)
bash "$BASE/map.sh" --no-launch --depth 2 --max-screens 40 --max-actions 8 --delay 1.5

# 5) Stop ADB local (sera aussi appelé par le trap)
ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" stop

# 6) Affiche le dernier run
echo
echo "Dernier run map:"
ls -1dt "$BASE/map/"* 2>/dev/null | head -n 1 || echo "(aucun dossier map)"
