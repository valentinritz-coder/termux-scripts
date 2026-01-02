cat > /sdcard/cfl_watch/update_from_github.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

REPO_SLUG="valentinritz-coder/termux-scripts"
REPO_URL="https://github.com/${REPO_SLUG}.git"
SUBDIR="${SUBDIR:-sh}"   # laisse "sh" si c'est là que tu ranges tes .sh dans le repo

DEST="/sdcard/cfl_watch"
WORK="$HOME/.cache/cfl_watch_repo"

# Fichiers à déployer dans DEST
FILES_DEST=(
  adb_local.sh
  map.sh
  map_run.sh
  scenario_trip.sh
  runner.sh
  snap.sh
)

# Fichiers à déployer dans DEST/tmp
FILES_TMP=(
  console.sh
)

die(){ echo "[!] $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[ -d /sdcard ] || die "/sdcard indisponible. Fais: termux-setup-storage"
have git || die "git absent. Fais: pkg install -y git"
have python || die "python absent (utilisé pour afficher les diffs). Fais: pkg install -y python"

mkdir -p "$DEST" "$DEST/logs" "$DEST/tmp"

echo "[*] Repo: $REPO_SLUG"
echo "[*] Workdir: $WORK"
echo "[*] Deploy -> $DEST (et $DEST/tmp)"

# --- Récupération du repo (clone ou update) ---
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

# --- Détection du dossier source ---
SRC="$WORK/$SUBDIR"
if [ ! -d "$SRC" ]; then
  # fallback: racine
  SRC="$WORK"
fi
echo "[*] Source scripts: $SRC"
echo "[*] Upstream: commit=$NEW_COMMIT branch=$NEW_BRANCH"

# --- Helpers ---
find_src() {
  # cherche d'abord dans SRC, puis à la racine (utile si console.sh est à la racine)
  local f="$1"
  if [ -f "$SRC/$f" ]; then
    echo "$SRC/$f"
  elif [ -f "$WORK/$f" ]; then
    echo "$WORK/$f"
  else
    echo ""
  fi
}

show_diff() {
  local src="$1"
  local dst="$2"
  python - "$src" "$dst" <<'PY'
import sys, difflib, pathlib
src, dst = sys.argv[1], sys.argv[2]
sp = pathlib.Path(src)
dp = pathlib.Path(dst)

s = sp.read_text(errors="replace").splitlines(True) if sp.exists() else []
d = dp.read_text(errors="replace").splitlines(True) if dp.exists() else []

name_src = str(sp)
name_dst = str(dp)
ud = difflib.unified_diff(d, s, fromfile=name_dst, tofile=name_src, lineterm="")
out = list(ud)

# Limite le volume affiché (sinon on imprime l'encyclopédie)
MAX = 260
if len(out) > MAX:
  out = out[:MAX] + ["... (diff tronqué) ..."]

print("\n".join(out) if out else "(no diff)")
PY
}

files_changed=0
declare -a PLAN_SRC PLAN_DST PLAN_MODE

plan_add() {
  PLAN_SRC+=("$1")
  PLAN_DST+=("$2")
  PLAN_MODE+=("$3") # DEST or TMP
}

# --- Construire le plan de déploiement ---
for f in "${FILES_DEST[@]}"; do
  src_path="$(find_src "$f")"
  [ -n "$src_path" ] || { echo "[!] Manquant dans le repo: $f (skip)"; continue; }
  plan_add "$src_path" "$DEST/$f" "DEST"
done

for f in "${FILES_TMP[@]}"; do
  src_path="$(find_src "$f")"
  [ -n "$src_path" ] || { echo "[!] Manquant dans le repo: $f (skip)"; continue; }
  plan_add "$src_path" "$DEST/tmp/$f" "TMP"
done

# --- Détecter les changements ---
echo
echo "[*] Analyse des changements..."
declare -a CHANGED_IDX
for i in "${!PLAN_SRC[@]}"; do
  src="${PLAN_SRC[$i]}"
  dst="${PLAN_DST[$i]}"

  if [ ! -f "$dst" ]; then
    echo " [+] NEW  -> ${dst}"
    CHANGED_IDX+=("$i")
    continue
  fi

  # compare contenu
  if ! python - "$src" "$dst" <<'PY' >/dev/null 2>&1
import sys, pathlib
a=pathlib.Path(sys.argv[1]).read_bytes()
b=pathlib.Path(sys.argv[2]).read_bytes()
raise SystemExit(0 if a==b else 1)
PY
  then
    echo " [~] MOD  -> ${dst}"
    CHANGED_IDX+=("$i")
  fi
done

if [ "${#CHANGED_IDX[@]}" -eq 0 ]; then
  echo "[+] Aucun changement à appliquer."
  exit 0
fi

echo
echo "=== DIFFS (aperçu) ==="
for i in "${CHANGED_IDX[@]}"; do
  src="${PLAN_SRC[$i]}"
  dst="${PLAN_DST[$i]}"
  echo
  echo "----- $dst -----"
  show_diff "$src" "$dst" || true
done

echo
read -r -p "Appliquer ces changements ? [y/N] " ans
case "${ans:-}" in
  y|Y|yes|YES|o|O|oui|OUI) ;;
  *) echo "[*] Annulé. Rien n'a été modifié."; exit 0 ;;
esac

echo
echo "[*] Application..."
for i in "${CHANGED_IDX[@]}"; do
  src="${PLAN_SRC[$i]}"
  dst="${PLAN_DST[$i]}"

  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
  sed -i 's/\r$//' "$dst" 2>/dev/null || true
  chmod +x "$dst" 2>/dev/null || true
  echo " [+] Deployed: $dst"
done

# Stamp version
{
  echo "repo=$REPO_SLUG"
  echo "updated=$(date -Iseconds)"
  echo "commit=$NEW_COMMIT"
  echo "branch=$NEW_BRANCH"
  echo "src=$SRC"
} > "$DEST/VERSION.txt"

echo
echo "[+] OK. VERSION:"
cat "$DEST/VERSION.txt" || true
SH

chmod +x /sdcard/cfl_watch/update_from_github.sh
sed -i 's/\r$//' /sdcard/cfl_watch/update_from_github.sh 2>/dev/null || true
