#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

REPO_SLUG="valentinritz-coder/termux-scripts"
REPO_URL="https://github.com/${REPO_SLUG}.git"
SUBDIR="${SUBDIR:-sh}"

DEST="${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}"
if [ -f "$HOME/cfl_watch/lib/path.sh" ]; then
  . "$HOME/cfl_watch/lib/path.sh"
  DEST="$(expand_tilde_path "$DEST")"
else
  DEST="${DEST/#\~/$HOME}"
fi
WORK="$HOME/.cache/cfl_watch_repo"

CONSOLE_NAME="console.sh"
CONSOLE_DST="$DEST/tmp/console.sh"

# Dossiers à NE JAMAIS toucher côté DEST
PROTECT_DIRS=(tmp logs map runs)

die(){ echo "[!] $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

have git || die "git absent. Fais: pkg install -y git"
have rsync || die "rsync absent. Fais: pkg install -y rsync"

# Assure l'existence des dossiers runtime
mkdir -p "$DEST"
for d in "${PROTECT_DIRS[@]}"; do
  mkdir -p "$DEST/$d"
done

echo "[*] Repo: $REPO_SLUG"
echo "[*] Workdir: $WORK"
echo "[*] Deploy -> $DEST (console -> $CONSOLE_DST)"

# --- Récupération du repo ---
if [ -d "$WORK/.git" ]; then
  echo "[*] Update (git fetch/pull)..."
  git -C "$WORK" fetch --all --prune
  git -C "$WORK" pull --ff-only 2>/dev/null || true
else
  echo "[*] Clone..."
  rm -rf "$WORK"
  mkdir -p "$(dirname "$WORK")"
  git clone "$REPO_URL" "$WORK" || die "Clone échoué (repo privé?)."
fi

NEW_COMMIT="$(git -C "$WORK" rev-parse --short HEAD 2>/dev/null || true)"
NEW_BRANCH="$(git -C "$WORK" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
echo "[*] Upstream: commit=$NEW_COMMIT branch=$NEW_BRANCH"

SRC_DIR="$WORK/$SUBDIR"
[ -d "$SRC_DIR" ] || die "Dossier source introuvable: $SRC_DIR"

# console.sh peut être à la racine ou dans sh/
CONSOLE_SRC=""
if [ -f "$WORK/$CONSOLE_NAME" ]; then
  CONSOLE_SRC="$WORK/$CONSOLE_NAME"
elif [ -f "$SRC_DIR/$CONSOLE_NAME" ]; then
  CONSOLE_SRC="$SRC_DIR/$CONSOLE_NAME"
fi

# --- Options rsync: copie TOUT sh/ -> DEST/ mais protège les dossiers runtime ---
RSYNC_OPTS=( -rc --itemize-changes --delete
  --exclude '.git/' --exclude '.github/'
)

# IMPORTANT: exclure les dossiers runtime du DEST pour éviter suppression
for d in "${PROTECT_DIRS[@]}"; do
  RSYNC_OPTS+=( --exclude "$d/" )
done

echo
echo "[*] Analyse des changements (preview)..."
RSYNC_OUT="$(rsync -n "${RSYNC_OPTS[@]}" "$SRC_DIR"/ "$DEST"/ || true)"
CHANGES_SH="$(echo "$RSYNC_OUT" | sed '/^$/d' || true)"

CHANGES_CONSOLE=""
if [ -n "$CONSOLE_SRC" ]; then
  if [ ! -f "$CONSOLE_DST" ]; then
    CHANGES_CONSOLE="[+] NEW  -> $CONSOLE_DST"
  else
    if ! cmp -s "$CONSOLE_SRC" "$CONSOLE_DST"; then
      CHANGES_CONSOLE="[~] MOD  -> $CONSOLE_DST"
    fi
  fi
else
  echo "[!] $CONSOLE_NAME introuvable dans le repo (skip console deploy)"
fi

if [ -z "$CHANGES_SH" ] && [ -z "$CHANGES_CONSOLE" ]; then
  echo "[+] Aucun changement à appliquer."
  exit 0
fi

echo
echo "=== CHANGES (sh/ -> $DEST) ==="
if [ -n "$CHANGES_SH" ]; then
  echo "$CHANGES_SH"
else
  echo "(aucun changement dans sh/)"
fi

echo
echo "=== CHANGES (console -> tmp) ==="
if [ -n "$CHANGES_CONSOLE" ]; then
  echo "$CHANGES_CONSOLE"
else
  echo "(aucun changement console)"
fi

echo
read -r -p "Appliquer ces changements ? [y/N] " ans
case "${ans:-}" in
  y|Y|yes|YES|o|O|oui|OUI) ;;
  *) echo "[*] Annulé. Rien n'a été modifié."; exit 0 ;;
esac

echo
echo "[*] Application sh/ -> $DEST ..."
rsync "${RSYNC_OPTS[@]}" "$SRC_DIR"/ "$DEST"/

# Re-crée les dossiers runtime (au cas où, mais normalement ils ne bougent pas)
for d in "${PROTECT_DIRS[@]}"; do
  mkdir -p "$DEST/$d"
done

# Normalise CRLF + chmod +x pour tous les .sh déployés (récursif)
find "$DEST" -type f -name '*.sh' -print0 2>/dev/null | while IFS= read -r -d '' f; do
  sed -i 's/\r$//' "$f" 2>/dev/null || true
  chmod +x "$f" 2>/dev/null || true
done

# Déploiement console.sh -> tmp/console.sh
if [ -n "$CONSOLE_SRC" ]; then
  echo "[*] Deploy console -> $CONSOLE_DST"
  mkdir -p "$(dirname "$CONSOLE_DST")"
  cp -f "$CONSOLE_SRC" "$CONSOLE_DST"
  sed -i 's/\r$//' "$CONSOLE_DST" 2>/dev/null || true
  chmod +x "$CONSOLE_DST" 2>/dev/null || true
fi

# VERSION
{
  echo "repo=$REPO_SLUG"
  echo "updated=$(date -Iseconds)"
  echo "commit=$NEW_COMMIT"
  echo "branch=$NEW_BRANCH"
  echo "src_dir=$SRC_DIR"
  echo "protected_dirs=${PROTECT_DIRS[*]}"
} > "$DEST/VERSION.txt"

echo
echo "[+] OK. VERSION:"
cat "$DEST/VERSION.txt" || true
