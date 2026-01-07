# CFL Watch (Termux)

Automatisation **CFL** (Android) qui s’exécute **directement sur le téléphone** via **Termux** + **ADB TCP local**.  
**Le mode sans LLM est la voie par défaut**: robuste, simple, et recommandé.

---

## Objectif

- Lancer des scénarios d’automatisation (ex: `scenario_trip.sh`).
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
bash "$HOME/termux-scripts/cfl_watch/tools/install_termux.sh" --update
```

---

## Utilisation (sans LLM par défaut)

### 1) Démarrer ADB local (root)
```bash
ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/lib/adb_local.sh" start
adb devices -l
```

### 2) Lancer un run
```bash
ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/runner.sh"
```

### 3) Un trajet précis
```bash
ADB_TCP_PORT=37099 SNAP_MODE=3 bash "$HOME/cfl_watch/runner.sh" \
  --start "LUXEMBOURG" --target "ARLON"
```

### 4) Viewer
```bash
bash "$HOME/cfl_watch/runner.sh" --serve
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

---

## Structure du repo (Termux)

### Code (Termux home)
```
$HOME/cfl_watch
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

- `CFL_CODE_DIR` (par défaut `$HOME/cfl_watch`)
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
- Lance `bash "$HOME/cfl_watch/runner.sh" --help`.

### “pas de ui.xml” / dump vide
- `uiautomator` ne peut pas écrire dans `CFL_TMP_DIR`.
- Lance `bash "$HOME/cfl_watch/tools/self_check.sh"`.

### “adb not found”
- Installe les deps: `pkg install -y android-tools`.

### ADB TCP non reachable
- `adb_local.sh start` (root requis), puis `adb devices -l`.

---

## LLM (optionnel)

Le LLM est **secondaire** et **optionnel**. Il ne doit pas être le chemin par défaut.

Activation rapide:
```bash
export LLM_INSTRUCTION="Ouvre CFL et fais un itinéraire Luxembourg -> Arlon"
ADB_TCP_PORT=37099 bash "$HOME/cfl_watch/runner.sh" --instruction "$LLM_INSTRUCTION"
```

---

## Notes

- Évitez `~` dans les variables (préférez `$HOME`).
- Le viewer se sert via `python -m http.server` dans le dossier `viewers/`.
