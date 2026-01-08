# CFL Watch (Termux)

Automatisation **CFL** (Android) qui s’exécute **directement sur le téléphone** via **Termux** + **ADB TCP local**.  
**Le mode sans LLM est la voie par défaut**: robuste, simple, et recommandé.

---

## Objectif

- Lancer des scénarios d’automatisation (ex: `trip_api.sh`).
- Capturer des artefacts (PNG/XML) et générer un viewer HTML.
- Garder l’option LLM **minimale et non bloquante**.

---

## Prérequis

- Pixel **rooté** (ADB TCP local).
- Termux installé.
- Accès stockage partagé Termux (`termux-setup-storage`).

---

## Installation (copier/coller)

```bash
pkg install -y git

git clone https://github.com/valentinritz-coder/termux-scripts.git "$HOME/termux-scripts"

bash "$HOME/termux-scripts/cfl_watch/tools/install_termux.sh"
```

Mise à jour (pull + perms + self-check):
```bash
cd "$HOME/termux-scripts" && git fetch --all --prune && git reset --hard @{u} && git clean -fd && bash "$HOME/termux-scripts/cfl_watch/tools/install_termux.sh"
```

Reset:
```bash
cd "$HOME/termux-scripts"

git fetch origin --prune

git reset --hard origin/main

git clean -fd

bash "$HOME/termux-scripts/cfl_watch/tools/install_termux.sh"
```

---

## Utilisation (sans LLM par défaut)

### 0) Config via `env.sh` (optionnel)
Les scripts chargent automatiquement `env.sh` (et `env.local.sh` si présent) depuis le dossier du projet.  
Vous pouvez soit modifier `env.sh`, soit créer un `env.local.sh` non versionné pour vos overrides persistants.

Exemple d’override ponctuel (prioritaire sur `env.sh`) :
```bash
CFL_SCENARIO_SCRIPT="$HOME/termux-scripts/cfl_watch/scenarios/trip_api.sh" \
ADB_TCP_PORT=37099 \
bash "$HOME/termux-scripts/cfl_watch/runner.sh" --list
```

### 1) Démarrer ADB local (root)
```bash
ADB_TCP_PORT=37099 bash "$HOME/termux-scripts/cfl_watch/lib/adb_local.sh" start
adb devices -l
```

### 2) Un trajet précis
```bash
ADB_TCP_PORT=37099 \
CFL_REMOTE_TMP_DIR=/data/local/tmp/cfl_watch \
CFL_TMP_DIR="$HOME/.cache/cfl_watch" \
CFL_SCENARIO_SCRIPT="$HOME/termux-scripts/cfl_watch/scenarios/trip_api.sh" \
bash "$HOME/termux-scripts/cfl_watch/runner.sh" --no-anim \
  --start "LUXEMBOURG" --target "ARLON" --snap-mode 3
```

### 3) Trois trajets aléatoires (N=3)
```bash
N=3 \
SLEEP_BETWEEN=1 \
ADB_TCP_PORT=37099 \
STATIONS_FILE="$HOME/termux-scripts/cfl_watch/data/stations.txt" \
STATIONS_FILE="$HOME/termux-scripts/cfl_watch/data/stations.txt" \
CFL_REMOTE_TMP_DIR=/data/local/tmp/cfl_watch \
CFL_TMP_DIR="$HOME/.cache/cfl_watch" \
SCENARIO="$HOME/termux-scripts/cfl_watch/scenarios/trip_api.sh" \
SNAP_MODE=3 \
NO_ANIM=1 \
bash "$HOME/termux-scripts/cfl_watch/tools/stress_stations.sh"
```

### 4) Un conteneur de trajets
```bash
TRIPS_FILE="$HOME/termux-scripts/cfl_watch/trips.txt" \
ADB_TCP_PORT=37099 \
CFL_REMOTE_TMP_DIR=/data/local/tmp/cfl_watch \
CFL_TMP_DIR="$HOME/.cache/cfl_watch" \
DEFAULT_SCENARIO="$HOME/termux-scripts/cfl_watch/scenarios/trip_api.sh" \
DEFAULT_SNAP_MODE=3 \
NO_ANIM=1 \
bash "$HOME/termux-scripts/cfl_watch/tools/batch_trips.sh"
```

### 5) Un enregistreur d'UI
```bash
SERIAL=127.0.0.1:37099 STABLE_SECS=2 bash "$HOME/termux-scripts/cfl_watch/tools/cfl_snap_watch.sh" ui_watch
```

### 6) Viewer
```bash
bash "$HOME/termux-scripts/cfl_watch/runner.sh" --serve
```

---

## Options utiles

- `--list` : scénarios intégrés
- `--check` : self-check (adb, uiautomator, /sdcard, python)
- `--dry-run` : log sans input events
- `--latest-run` : imprime le dernier run
- `--serve` : génère/sert le viewer (python -m http.server)
- `--no-anim` : désactiver temporairement les animations Android

`SNAP_MODE` : `0=off`, `1=png`, `2=xml`, `3=png+xml`

Outils utiles:
- `tools/doctor.sh` : diagnostics rapides (variables, chemins, env.sh).

---

## Structure du repo (Termux)

### Code (Termux home)
```
$HOME/termux-scripts/cfl_watch
├── runner.sh
├── lib/
│   ├── common.sh
│   ├── adb_local.sh
│   ├── snap.sh
│   └── viewer.sh
├── scenarios/
└── tools/
```

### Artefacts (stockage partagé)
```
/sdcard/cfl_watch
├── runs/      # artefacts par run (PNG/XML)
├── logs/      # logs des runs
└── tmp/       # uiautomator dumps
```

---

## Conventions & variables d’environnement

- `env.sh` fournit des valeurs par défaut sans écraser les variables déjà exportées.
- `env.local.sh` (optionnel, ignoré par git) permet d’ajouter vos overrides persistants.
- `CFL_CODE_DIR` (par défaut `$HOME/termux-scripts/cfl_watch`)
- `CFL_ARTIFACT_DIR` (par défaut `/sdcard/cfl_watch`)
- `CFL_TMP_DIR` (par défaut `$CFL_ARTIFACT_DIR/tmp`)
- `CFL_PKG` (par défaut `de.hafas.android.cfl`)
- `ADB_TCP_PORT`, `ADB_HOST`, `ANDROID_SERIAL`
- Delays: `DELAY_LAUNCH`, `DELAY_TAP`, `DELAY_TYPE`, `DELAY_PICK`, `DELAY_SEARCH`

> `CFL_TMP_DIR` doit être sur `/sdcard` pour que `uiautomator dump` fonctionne via adb.

---

## Troubleshooting

### “Scenario introuvable”
- Vérifie le chemin du script et `CFL_CODE_DIR`.
- Utilise `--list` pour lister les scénarios.

### “$2 unbound variable”
- Argument manquant (ex: `--start` ou `--target`).
- Lance `bash "$HOME/termux-scripts/cfl_watch/runner.sh" --help`.

### “pas de ui.xml” / dump vide
- `uiautomator` ne peut pas écrire dans `CFL_TMP_DIR`.
- Lance `bash "$HOME/termux-scripts/cfl_watch/tools/self_check.sh"`.

### “adb not found”
- Installe les deps: `pkg install -y android-tools`.

### ADB TCP non reachable
- `adb_local.sh start` (root requis), puis `adb devices -l`.

### GitHub Rebase : unstaged changes
```bash
cd "$HOME/termux-scripts"
git status
git diff
```
### Solution :
```bash
cd "$HOME/termux-scripts"
git add cfl_watch/lib/path.sh cfl_watch/lib/ui_api.sh cfl_watch/lib/ui_core.sh cfl_watch/lib/ui_select.sh \
        cfl_watch/scenarios/trip_api.sh \
        cfl_watch/tools/batch_trips.sh cfl_watch/tools/cfl_snap_watch.sh cfl_watch/tools/llm_explore.sh cfl_watch/tools/stress_stations.sh

git commit -m "chmod +x: make shell scripts executable"
git pull --rebase
bash "$HOME/termux-scripts/cfl_watch/tools/install_termux.sh"
```

---

## LLM (optionnel)

Le LLM est **secondaire** et **optionnel**. Il ne doit pas être le chemin par défaut.

Activation rapide:
```bash
export LLM_INSTRUCTION="Ouvre CFL et fais un itinéraire Luxembourg -> Arlon"
ADB_TCP_PORT=37099 bash "$HOME/termux-scripts/cfl_watch/runner.sh" --instruction "$LLM_INSTRUCTION"
```

---

## Notes

- Évitez `~` dans les variables (préférez `$HOME`).
- Le viewer se sert via `python -m http.server` dans le dossier `viewers/`.
