# AUDIT — CFL WATCH (Termux)

> Hypothèse explicite : le flux principal est `runner.sh` qui charge un scénario (par défaut `scenarios/trip_api_datetime.sh`) et génère des artefacts sous `/sdcard/cfl_watch`.

## 0) Résumé exécutif (10 lignes max)
1. Repo d’automatisation CFL sur Android, exécuté **sur le téléphone** via Termux + ADB TCP local.
2. Point d’entrée principal : `cfl_watch/runner.sh` (sélection du scénario, logs, viewer).
3. Scénario par défaut : `scenarios/trip_api_datetime.sh`, appuie sur l’UI et capture des snaps XML/PNG.
4. Bibliothèques UI centralisées dans `lib/ui_*.sh` avec dump UI + waits + taps.
5. Artefacts sous `/sdcard/cfl_watch` (runs, logs, tmp) et viewer HTML (`lib/viewer.sh`).
6. Les risques majeurs : fragilité UI (selectors/états), latence/race conditions, chemins tmp et droits ADB.
7. Observabilité correcte (logs + snaps), mais pas de corrélation run-id globale et peu de résumés finaux.
8. Plusieurs scripts sont stricts (`set -euo pipefail`), certains outils ne le sont pas (`set -u` seulement).
9. Les timings et répertoires clés sont parametrables via `env.sh` / `env.local.sh`.
10. Améliorations proposées : corrélation run-id, normalisation logs, checks robustes ADB/tmp, résumé final.

---

## 1) Inventaire

### Dossiers clés
- `cfl_watch/lib/` : bibliothèque Bash (ADB, UI, snapshots, viewer, utilitaires).
- `cfl_watch/scenarios/` : scénarios UI (exécution métier).
- `cfl_watch/tools/` : outils de maintenance, stress tests, installation Termux.
- `cfl_watch/data/` : données statiques (ex: stations).
- `/sdcard/cfl_watch/` : artefacts runtime (runs, logs, tmp).

### Entrypoints & usages

**Entrypoint principal**
- `cfl_watch/runner.sh`
  - Lance un scénario (par défaut `scenarios/trip_api_datetime.sh`).
  - Charge `env.sh` + `env.local.sh` si présents.
  - Options utiles : `--scenario`, `--start`, `--target`, `--via`, `--snap-mode`, `--no-anim`, `--check`, `--serve`.
  - Env vars importantes :
    - `CFL_SCENARIO_SCRIPT`, `CFL_PKG`, `CFL_ARTIFACT_DIR`, `CFL_TMP_DIR`, `CFL_REMOTE_TMP_DIR`, `ADB_TCP_PORT`, `ADB_HOST`, `CFL_DRY_RUN`.

**Scénarios**
- `cfl_watch/scenarios/trip_api_datetime.sh`
  - Scénario principal. Utilise UI dumps + actions + snaps.
  - Inputs : `START_TEXT`, `TARGET_TEXT`, `VIA_TEXT`, `DATE_YMD`, `TIME_HM`, `SNAP_MODE`.

**Outils & diagnostics**
- `cfl_watch/tools/self_check.sh` : vérifie ADB, accès storage, uiautomator.
- `cfl_watch/tools/doctor.sh` : diagnostic non bloquant (warns).
- `cfl_watch/tools/stress_stations.sh` : stress test aléatoire (N runs).
- `cfl_watch/tools/batch_trips.sh` : batch de trajets depuis fichier.
- `cfl_watch/tools/cfl_snap_watch.sh` : enregistreur d’UI.
- `cfl_watch/tools/install_termux.sh` : setup deps + permissions.
- `cfl_watch/lib/adb_local.sh` : ADB TCP local start/stop.

---

## 2) Flux de bout en bout

```
[termux bash] 
   |
   v
runner.sh (charge env + common)
   |
   +--> scenario.sh (trip_api_datetime.sh)
          |
          +--> lib/ui_core.sh  (dump UI, wait, regex selectors)
          +--> lib/ui_select.sh / ui_api.sh / ui_datetime.sh
          +--> lib/snap.sh     (xml/png snapshots)
          |
          +--> actions ADB (tap/type/scroll)
          |
          v
   /sdcard/cfl_watch/runs/<timestamp>_run_name/
       ├── xml/   (uiautomator dumps)
       ├── png/   (screenshots)
       └── viewers/ (html viewer)
```

**Frontières**
- **Script ↔ ADB/Device** : `adb shell` / `uiautomator dump` / `screencap`.
- **Termux ↔ Storage** : `CFL_ARTIFACT_DIR` + `CFL_TMP_DIR` (local) vs `CFL_REMOTE_TMP_DIR` (device).

---

## 3) Observabilité & debug

### État actuel
- Logs : format simple (`log`, `warn`) dans `lib/common.sh` + logs structurés ISO-8601 dans le scénario principal.
- Artefacts : `runs/<timestamp>_name/{xml,png}` + viewer HTML.
- Manque : corrélation “run-id” globale entre runner/scenario/libs.

### Améliorations rapides (3–5)
1. **ID de run global**
   - Générer `CFL_RUN_ID` au début du runner et l’exporter.
   - Inclure `CFL_RUN_ID` dans le nom de `SNAP_DIR` et en prefix des logs.
   - Test : vérifier le run-id commun dans log + dossier run.

2. **Résumé fin de run**
   - Écrire un `summary.txt` avec start/target/via/rc + paths.
   - Test : fichier présent dans `runs/<run>/summary.txt`.

3. **Uniformiser les logs**
   - Ajouter timestamp ISO-8601 dans `log()` de `lib/common.sh` (optionnel via env).
   - Test : logs comportent `YYYY-MM-DDTHH:MM:SS±TZ`.

4. **Validation artefacts**
   - Vérifier que `xml/` et `png/` ne sont pas vides avant viewer.
   - Test : warning si snapshots manquants.

---

## 4) Robustesse Bash/Android

### Observations
- Plusieurs scripts utilisent `set -euo pipefail`, mais certains tools n’ont que `set -u` (ex: stress).
- Quoting globalement correct, mais certains chemins et variables dépendantes de l’environnement peuvent être vides.
- `uiautomator dump` est sensible aux transitions UI : race conditions possibles.
- Risques spécifiques Android : latence UI, animations, état réseau/horloge, dumps vides.

### Fixes minimaux suggérés
1. **Wrapper ADB shell robuste**
   - Ajouter un helper `safe_adb_shell` avec retries courts (dump/tap).
   - Test : forcer une UI instable et vérifier retry.

2. **Normalisation CRLF**
   - Stripper `\r` systématiquement dans les retours ADB (déjà fait dans certains endroits).
   - Test : comparer output de dumpsys avec/ sans `tr -d '\r'`.

3. **Stabilité UI**
   - Introduire un petit `wait_ui_stable` (2 dumps identiques) avant actions critiques.
   - Test : UI en transition -> action retardée jusqu’à stabilité.

4. **Check `CFL_TMP_DIR` et `CFL_REMOTE_TMP_DIR`**
   - Harmoniser les warnings doctor/self-check et protéger les chemins.
   - Test : run avec `CFL_TMP_DIR` invalide → erreur claire.

---

## 5) Test & validation

### Plan recommandé
1. **Smoke test**
   - `bash cfl_watch/tools/self_check.sh`
   - Réussite : `Self-check OK.` + dump uiautomator valide.

2. **Run scénario simple**
   - `START_TEXT="LUXEMBOURG" TARGET_TEXT="ARLON" SNAP_MODE=2 bash cfl_watch/runner.sh --no-anim`
   - Réussite : dossier `runs/<timestamp>_.../xml/*.xml` non vide + log sans erreur.

3. **Stress test court**
   - `N=3 SNAP_MODE=1 bash cfl_watch/tools/stress_stations.sh`
   - Réussite : `DONE: ok=3 fail=0`.

4. **Non-root (si applicable)**
   - Démarrer ADB TCP via `adb_local.sh` si root, sinon fallback via USB/ADB.
   - Vérifier que `adb devices -l` retourne le device attendu.

5. **Multi-device**
   - `ANDROID_SERIAL=<serial> bash cfl_watch/runner.sh ...`
   - Réussite : run créé pour le device ciblé.

---

## 6) Backlog priorisé (Impact / Effort)

### Quick wins (≤ 30 min)
- Ajouter `CFL_RUN_ID` (logs + artefacts) pour corrélation.
- Ajouter `summary.txt` par run (inputs, rc, paths).
- Corriger les warnings incohérents dans `doctor.sh`.

### Améliorations moyennes (½ journée)
- Wrapper `safe_adb_shell` + retry (dump/tap/scroll).
- `wait_ui_stable` pour éviter les dumps vides en transition.
- Normaliser les logs (timestamp optionnel au niveau `lib/common.sh`).

### Refactors lourds (justifiés)
- Pipeline de snapshot unifié (capture + validation + viewer) avec métriques.
- Module central d’observabilité (logs JSON + summary par étape).
- Tests de non-régression UI via diff automatique des dumps.

---

## 7) Patches (optionnel)

Aucun patch proposé dans ce rapport.
Si besoin, je peux fournir des diffs unifiés pour :
- Ajout `CFL_RUN_ID`,
- Ajout `summary.txt`,
- Réconciliation des warnings dans `tools/doctor.sh`.

Chaque patch inclura : pourquoi, comment tester, risques.
