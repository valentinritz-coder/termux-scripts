#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

cleanup() {
  adb -s "${ANDROID_SERIAL:-127.0.0.1:5555}" shell am force-stop de.hafas.android.cfl >/dev/null 2>&1 || true
  echo "DONE $(date -Iseconds)" > /sdcard/cfl_watch/logs/LAST_DONE.txt
  command -v termux-toast >/dev/null 2>&1 && termux-toast "CFL watch terminé"
}
trap cleanup EXIT

export ANDROID_SERIAL=127.0.0.1:5555
BASE="/sdcard/cfl_watch"

mkdir -p "$BASE"/{logs,map,tmp}

# Si tu as le script d'update (optionnel)
[ -x "$BASE/update_from_github.sh" ] && bash "$BASE/update_from_github.sh" >/dev/null 2>&1 || true

# 1) Start ADB local
bash "$BASE/adb_local.sh" start

# 2) Ouvre CFL (best effort)
adb -s "$ANDROID_SERIAL" shell monkey -p de.hafas.android.cfl -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 2

# 3) Scénario: remplir start/destination + search (adapte les stations)
#    (si ça échoue, on continue quand même)
bash "$BASE/scenario_trip.sh" "Luxembourg" "Arlon" >/dev/null 2>&1 || true

# 4) Mapping depuis l'écran courant (ne relance pas)
bash "$BASE/map.sh" --no-launch --depth 2 --max-screens 40 --max-actions 8 --delay 1.5

# 5) Stop ADB local
bash "$BASE/adb_local.sh" stop

# 6) Affiche le dernier run
echo
echo "Dernier run map:"
ls -1dt "$BASE/map/"* 2>/dev/null | head -n 1 || echo "(aucun dossier map)"

# --- FIN: fermeture + signal ---
adb -s "$ANDROID_SERIAL" shell am force-stop de.hafas.android.cfl >/dev/null 2>&1 || true

# marqueur de fin
echo "DONE $(date -Iseconds)" > /sdcard/cfl_watch/logs/LAST_DONE.txt

# notification si dispo
if command -v termux-toast >/dev/null 2>&1; then
  LAST_MAP="$(ls -1dt /sdcard/cfl_watch/map/* 2>/dev/null | head -n 1 || true)"
  termux-toast "Terminé. Dernier map: ${LAST_MAP:-none}"
fi

echo "[*] Terminé."
