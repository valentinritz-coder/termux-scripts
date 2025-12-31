#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="/sdcard/cfl_watch"
PKG="de.hafas.android.cfl"
PREF_SERIAL="127.0.0.1:5555"

mkdir -p "$BASE"/{logs,map,tmp}

pick_serial() {
  # Préfère 127.0.0.1:5555 si présent, sinon prend le premier "device"
  local s
  s="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}' | head -n 1)"
  if adb devices 2>/dev/null | awk 'NR>1 && $1=="'"$PREF_SERIAL"'" && $2=="device"{exit 0} END{exit 1}'; then
    echo "$PREF_SERIAL"
  else
    echo "${s:-$PREF_SERIAL}"
  fi
}

wait_adb() {
  adb start-server >/dev/null 2>&1 || true
  adb connect "$PREF_SERIAL" >/dev/null 2>&1 || true

  local i serial
  for i in $(seq 1 150); do  # 150 * 0.2 = 30s
    serial="$(pick_serial)"
    # si le serial est "device", tente un shell
    if adb devices 2>/dev/null | awk 'NR>1 && $1=="'"$serial"'" && $2=="device"{exit 0} END{exit 1}'; then
      if adb -s "$serial" shell true >/dev/null 2>&1; then
        export ANDROID_SERIAL="$serial"
        return 0
      fi
    fi
    sleep 0.2
  done

  echo "[!] ADB pas prêt après 30s. Etat actuel:" >&2
  adb devices -l >&2 || true
  return 1
}

cleanup() {
  # Stop ADB local si présent
  [ -f "$BASE/adb_local.sh" ] && bash "$BASE/adb_local.sh" stop >/dev/null 2>&1 || true

  # Ferme CFL (best effort)
  if command -v adb >/dev/null 2>&1; then
    adb -s "${ANDROID_SERIAL:-$PREF_SERIAL}" shell am force-stop "$PKG" >/dev/null 2>&1 || true
  fi

  echo "DONE $(date -Iseconds)" > "$BASE/logs/LAST_DONE.txt" 2>/dev/null || true

  if command -v termux-toast >/dev/null 2>&1; then
    LAST_MAP="$(ls -1dt "$BASE/map/"* 2>/dev/null | head -n 1 || true)"
    termux-toast "CFL watch terminé. ${LAST_MAP:-no map dir}"
  fi
}
trap cleanup EXIT

# Update scripts (si présent)
[ -f "$BASE/update_from_github.sh" ] && bash "$BASE/update_from_github.sh" >/dev/null 2>&1 || true

# Start ADB local
bash "$BASE/adb_local.sh" start

# Attends ADB vraiment prêt
wait_adb

# Lance CFL
adb -s "$ANDROID_SERIAL" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 2

# Scenario (best effort)
bash "$BASE/scenario_trip.sh" "Luxembourg" "Arlon" >/dev/null 2>&1 || true

# Mapping depuis l'écran courant
bash "$BASE/map.sh" --no-launch --depth 2 --max-screens 40 --max-actions 8 --delay 1.5

echo
echo "Dernier run map:"
ls -1dt "$BASE/map/"* 2>/dev/null | head -n 1 || echo "(aucun dossier map)"
echo "[*] Terminé."
