cat > /sdcard/cfl_watch/snap.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
# Librairie à SOURCER: définit snap_init + snap
# Aucun effet de bord au chargement.

snap_init() {
  local name="${1:-run}"
  local base="${BASE:-/sdcard/cfl_watch}"
  local ts
  ts="$(date +%Y-%m-%d_%H-%M-%S)"

  # Crée les dossiers au moment où on en a besoin (best effort)
  mkdir -p "$base"/{runs,tmp,logs} 2>/dev/null || true

  export SNAP_DIR="$base/runs/${ts}_${name}"
  mkdir -p "$SNAP_DIR" 2>/dev/null || true
  echo "[*] SNAP_DIR=$SNAP_DIR"
}

snap() {
  local tag="${1:-snap}"
  local ser="${ANDROID_SERIAL:-127.0.0.1:37099}"
  local ts
  ts="$(date +%H-%M-%S)"

  if [ -z "${SNAP_DIR:-}" ]; then
    echo "[!] SNAP_DIR non défini. Appelle d'abord: snap_init \"nom_scenario\""
    return 1
  fi

  adb -s "$ser" shell uiautomator dump --compressed "$SNAP_DIR/${ts}_${tag}.xml" >/dev/null 2>&1 || true
  adb -s "$ser" shell screencap -p "$SNAP_DIR/${ts}_${tag}.png" >/dev/null 2>&1 || true
  echo "[*] snap: ${ts}_${tag}"
}

# Si exécuté directement, on prévient.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  echo "[!] snap.sh est une librairie. Utilise: . /sdcard/cfl_watch/snap.sh"
fi
SH

chmod +x /sdcard/cfl_watch/snap.sh
sed -i 's/\r$//' /sdcard/cfl_watch/snap.sh 2>/dev/null || true
