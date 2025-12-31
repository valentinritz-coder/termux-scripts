cat > /sdcard/cfl_watch/update_from_github.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

REPO_SLUG="valentinritz-coder/termux-scripts"
REPO_URL="https://github.com/${REPO_SLUG}.git"
SUBDIR="sh"

DEST="/sdcard/cfl_watch"
WORK="$HOME/.cache/cfl_watch_repo"

FILES=(adb_local.sh map.sh map_run.sh scenario_trip.sh)

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
  # pull best-effort (si pas d'upstream configuré, on ne meurt pas)
  git -C "$WORK" pull --ff-only 2>/dev/null || true
else
  echo "[*] Clone..."
  rm -rf "$WORK"
  mkdir -p "$(dirname "$WORK")"

  # Si gh est là ET authentifié, c'est le meilleur plan (repo privé OK)
  if have gh && gh auth status >/dev/null 2>&1; then
    gh repo clone "$REPO_SLUG" "$WORK"
  else
    echo "[*] (Si le repo est privé: fais une fois 'gh auth login' puis relance.)"
    if ! git clone "$REPO_URL" "$WORK"; then
      die "Clone échoué. Installe/relie GitHub: pkg install -y gh && gh auth login"
    fi
  fi
fi

SRC="$WORK/$SUBDIR"
[ -d "$SRC" ] || die "Dossier '$SUBDIR' introuvable dans le repo: $SRC"

echo "[*] Copie des scripts..."
for f in "${FILES[@]}"; do
  [ -f "$SRC/$f" ] || die "Fichier manquant: $SRC/$f"
  cp -f "$SRC/$f" "$DEST/$f"
  # Normalise CRLF si jamais un fichier a pris des \r
  sed -i 's/\r$//' "$DEST/$f" 2>/dev/null || true
done

# Stamp version
{
  echo "repo=$REPO_SLUG"
  echo "updated=$(date -Iseconds)"
  echo "commit=$(git -C "$WORK" rev-parse --short HEAD 2>/dev/null || true)"
  echo "branch=$(git -C "$WORK" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
} > "$DEST/VERSION.txt"

echo "[+] OK. Contenu déployé:"
ls -1 "$DEST" | grep -E '^(adb_local\.sh|map\.sh|map_run\.sh|scenario_trip\.sh|VERSION\.txt)$' || true
SH

chmod +x /sdcard/cfl_watch/update_from_github.sh
