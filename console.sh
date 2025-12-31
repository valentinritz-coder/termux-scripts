#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="/sdcard/cfl_watch"
PKG="de.hafas.android.cfl"
PREF_SERIAL="127.0.0.1:5555"

mkdir -p "$BASE"/{logs,map,tmp}

cleanup() {
  bash "$BASE/adb_local.sh" stop >/dev/null 2>&1 || true
  adb -s "${ANDROID_SERIAL:-$PREF_SERIAL}" shell am force-stop "$PKG" >/dev/null 2>&1 || true
  echo "DONE $(date -Iseconds)" > "$BASE/logs/LAST_DONE.txt" 2>/dev/null || true
  command -v termux-toast >/dev/null 2>&1 && termux-toast "CFL watch terminé"
}
trap cleanup EXIT

# Update scripts
[ -f "$BASE/update_from_github.sh" ] && bash "$BASE/update_from_github.sh" >/dev/null 2>&1 || true

# Start ADB local + status visible
bash "$BASE/adb_local.sh" start

# Si ADB ne voit rien, on stoppe ici (c'est ça ton bug)
if ! adb devices | awk 'NR>1{found=1} END{exit(found?0:1)}'; then
  echo "[!] ADB ne voit aucun device. Impossible de continuer."
  echo "[*] adb devices -l:"
  adb devices -l || true
  exit 1
fi

# Choix serial: préfère PREF_SERIAL s’il est device, sinon 1er device
if adb devices | awk 'NR>1 && $1=="'"$PREF_SERIAL"'" && $2=="device"{exit 0} END{exit 1}'; then
  export ANDROID_SERIAL="$PREF_SERIAL"
else
  export ANDROID_SERIAL="$(adb devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
fi

echo "[*] Using ANDROID_SERIAL=$ANDROID_SERIAL"

adb -s "$ANDROID_SERIAL" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 2

bash "$BASE/scenario_trip.sh" "Luxembourg" "Arlon" >/dev/null 2>&1 || true
bash "$BASE/map.sh" --no-launch --depth 2 --max-screens 40 --max-actions 8 --delay 1.5
