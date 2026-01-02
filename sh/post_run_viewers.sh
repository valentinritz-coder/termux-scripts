#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="/sdcard/cfl_watch"
PY="$BASE/make_ui_viewer.py"

SNAP_DIR="${1:-${SNAP_DIR:-}}"
[ -n "${SNAP_DIR}" ] || { echo "[!] Usage: bash post_run_viewers.sh <SNAP_DIR>  (ou export SNAP_DIR)"; exit 2; }
[ -d "$SNAP_DIR" ] || { echo "[!] SNAP_DIR introuvable: $SNAP_DIR"; exit 2; }
[ -f "$PY" ] || { echo "[!] Missing: $PY"; exit 2; }

OUT="$SNAP_DIR/viewers"
mkdir -p "$OUT"

echo "[*] SNAP_DIR=$SNAP_DIR"
echo "[*] OUT=$OUT"

# Pour chaque XML, on cherche le PNG avec le même préfixe (ex: 09-00-01_tag.xml <-> 09-00-01_tag.png)
count=0
for xml in "$SNAP_DIR"/*.xml; do
  [ -e "$xml" ] || continue
  png="${xml%.xml}.png"
  if [ ! -f "$png" ]; then
    echo "[!] PNG manquant pour: $(basename "$xml")"
    continue
  fi

  name="$(basename "${xml%.xml}")"
  out_dir="$OUT/$name"

  python "$PY" "$xml" "$png" "$out_dir" >/dev/null
  count=$((count+1))
done

echo "[+] Viewers générés: $count"

# Petit index HTML pour naviguer vite
INDEX="$OUT/index.html"
{
  echo "<!doctype html><meta charset='utf-8'><title>Viewers</title>"
  echo "<style>body{font-family:sans-serif;padding:12px} a{display:block;padding:6px 0}</style>"
  echo "<h2>UI Viewers</h2>"
  echo "<p>SNAP_DIR: $SNAP_DIR</p>"
  for d in "$OUT"/*; do
    [ -d "$d" ] || continue
    bn="$(basename "$d")"
    echo "<a href='./$bn/index.html'>$bn</a>"
  done
} > "$INDEX"

echo "[+] Index: $INDEX"
echo "[*] Pour ouvrir: cd '$OUT' && python -m http.server 8000"
