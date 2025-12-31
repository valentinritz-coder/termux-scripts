#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

export ANDROID_SERIAL=127.0.0.1:5555
BASE="/sdcard/cfl_watch"
PKG="de.hafas.android.cfl"

wait_adb() {
  # attend que adb réponde réellement
  local i
  for i in $(seq 1 25); do
    if adb -s "$ANDROID_SERIAL" shell true >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  echo "[!] ADB n'est pas prêt sur $ANDROID_SERIAL" >&2
  return 1
}

cleanup() {
  # Stop ADB local si possible
  [ -f "$BASE/adb_local.sh" ] && bash "$BASE/adb_local.sh" stop >/dev/null 2>&1 || true

  # Ferme CFL
  adb -s "${ANDROID_SERIAL}" shell am force-stop "$PKG" >/dev/null 2>&1 || true

  # Marqueur de fin
  mkdir -p "$BASE/logs" >/dev/null 2>&1 || true
  echo "DONE $(date -Iseconds)" > "$BASE/logs/LAST_DONE.txt" 2>/dev/null || true

  # Toast si dispo
  if command -v termux-toast >/dev/null 2>&1; then
    LAST_MAP="$(ls -1dt "$BASE/map/"* 2>/dev/null | head -n 1 || true)"
    termux-toast "CFL watch terminé. ${LAST_MAP:-no map dir}"
  fi
}
trap cleanup EXIT

mkdir -p "$BASE"/{logs,map,tmp}

# Update scripts (même si pas +x)
[ -f "$BASE/update_from_github.sh" ] && bash "$BASE/update_from_github.sh" >/dev/null 2>&1 || true

# 1) Start ADB local
bash "$BASE/adb_local.sh" start

# 2) Attends ADB prêt (sinon le 1er run fait semblant)
wait_adb

# 3) Ouvre CFL (et cette fois si ça échoue, on le SAIT)
adb -s "$ANDROID_SERIAL" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1
sleep 2

# 4) Scénario (best effort)
bash "$BASE/scenario_trip.sh" "Luxembourg" "Arlon" >/dev/null 2>&1 || true

# 5) Mapping depuis l'écran courant
bash "$BASE/map.sh" --no-launch --depth 2 --max-screens 40 --max-actions 8 --delay 1.5

echo
echo "Dernier run map:"
ls -1dt "$BASE/map/"* 2>/dev/null | head -n 1 || echo "(aucun dossier map)"

echo "[*] Terminé."
