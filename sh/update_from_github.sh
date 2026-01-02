cat > /sdcard/cfl_watch/update_from_github.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

REPO_SLUG="valentinritz-coder/termux-scripts"
REPO_URL="https://github.com/${REPO_SLUG}.git"

# Si tes scripts sont dans un sous-dossier du repo, mets-le ici.
# Si tu n’es pas sûr, laisse vide: le script auto-détecte.
SUBDIR="${SUBDIR:-sh}"

DEST="/sdcard/cfl_watch"
WORK="$HOME/.cache/cfl_watch_repo"

# Mets ici tous les scripts que tu veux déployer sur le téléphone
FILES=(
  adb_local.sh
  console.sh
  snap.sh
  runner.sh
  scenario_trip.sh
  map.sh
  map_run.sh
)

die() { echo "[!] $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -d /sdcard ] || die "/sdcard indisponible. Fais: termux-setup-storage"
have git || die "git absent. Fais: pkg install -y git"

mkdir -p "$DEST" "$DEST/logs" "$DEST/tmp"

echo "[*] Repo: $REPO_SLUG"
echo "[*] Workdir: $WORK"
echo "[*] Deploy -> $DEST"

# --- Récupération du repo (clone ou update) ---
if [ -d "$WORK/.git" ]; then
  echo "[*] Update (git fetch/pull)..."
  git -C "$WORK" fetch --all --prune
  git -C "$WORK" pull --ff-only 2>/dev/null || true
else
  echo "[*] Clone..."
  rm -rf "$WORK"
  mkdir -p "$(dirname "$WORK")"
  if ! git clone "$REPO_URL" "$WORK"; then
    die "Clone échoué (repo privé?). Solution: pkg install -y gh && gh auth login, ou clone via token."
  fi
fi

# --- Détection du dossier source ---
SRC="$WORK"
if [ -n "$SUBDIR" ] && [ -d "$WORK/$SUBDIR" ]; then
  SRC="$WORK/$SUBDIR"
else
  # auto-detect si SUBDIR n’existe pas
  if [ -d "$WORK/sh" ]; then
    SRC="$WORK/sh"
  fi
fi

echo "[*] Source scripts: $SRC"

echo "[*] Copie des scripts..."
for f in "${FILES[@]}"; do
  if [ ! -f "$SRC/$f" ]; then
    echo "[!] Manquant dans le repo: $SRC/$f (skip)"
    continue
  fi

  cp -f "$SRC/$f" "$DEST/$f"
  sed -i 's/\r$//' "$DEST/$f" 2>/dev/null || true
  chmod +x "$DEST/$f" 2>/dev/null || true
  echo "    - $f"
done

# Stamp version
{
  echo "repo=$REPO_SLUG"
  echo "updated=$(date -Iseconds)"
  echo "commit=$(git -C "$WORK" rev-parse --short HEAD 2>/dev/null || true)"
  echo "branch=$(git -C "$WORK" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  echo "src=$SRC"
} > "$DEST/VERSION.txt"

echo "[+] OK. VERSION:"
cat "$DEST/VERSION.txt" || true

echo "[+] Scripts présents dans $DEST:"
ls -1 "$DEST" | grep -E '\.sh$|^VERSION\.txt$' || true
SH

chmod +x /sdcard/cfl_watch/update_from_github.sh
sed -i 's/\r$//' /sdcard/cfl_watch/update_from_github.sh 2>/dev/null || true
