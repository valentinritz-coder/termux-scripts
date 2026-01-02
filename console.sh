#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# --- ADB local config ---
HOST="${ADB_HOST:-127.0.0.1}"
PORT="${ADB_TCP_PORT:-37099}"
SERIAL="${ADB_SERIAL:-$HOST:$PORT}"
export ANDROID_SERIAL="$SERIAL"

BASE="/sdcard/cfl_watch"
mkdir -p "$BASE"/{logs,map,tmp}
cd "$BASE"

ADB_STARTED=0
TS="$(date +%Y-%m-%d_%H-%M-%S)"
LOG="$BASE/logs/console_$TS.log"

# Log console (stdout+stderr) dans un fichier + à l'écran
exec > >(tee -a "$LOG") 2>&1

cleanup() {
  if [[ "$ADB_STARTED" == "1" ]]; then
    ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" stop >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "[*] SERIAL=$SERIAL (PORT=$PORT)"
echo "[*] LOG=$LOG"

# Update optionnel
[ -x "$BASE/update_from_github.sh" ] && bash "$BASE/update_from_github.sh" || true

# 1) Start ADB local
ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" start
ADB_STARTED=1

# 2) Ouvre CFL (best effort)
adb shell monkey -p de.hafas.android.cfl -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 2

# 3) Scénario (best effort)
bash "$BASE/scenario_trip.sh" "Luxembourg" "Arlon" || true

# 4) Mapping (ne relance pas) - on garde le rc sans tuer toute la console
set +e
bash "$BASE/map.sh" --no-launch --depth 2 --max-screens 40 --max-actions 8 --delay 1.5
MAP_RC=$?
set -e
echo "[*] map.sh rc=$MAP_RC"

# 5) Stop ADB local (une seule fois)
ADB_TCP_PORT="$PORT" bash "$BASE/adb_local.sh" stop
ADB_STARTED=0

# 6) Affiche le dernier run
echo
echo "Dernier run map:"
ls -1dt "$BASE/map/"* 2>/dev/null | head -n 1 || echo "(aucun dossier map)"
