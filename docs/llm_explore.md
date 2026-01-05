# LLM explorer (expérimental)

Ce mode pilote l'app CFL Android via adb en s'appuyant sur un dump uiautomator et un LLM local exposé avec une API compatible OpenAI.

> ⚠️ Expérimental et instable : préparez-vous à relancer ou corriger manuellement si besoin.

## Pré-requis

- adb fonctionne déjà en local (env `ANDROID_SERIAL` pointant sur le device/emulateur, ex: `127.0.0.1:37099`).
- Le LLM est accessible via HTTP sur une API OpenAI-compatible :
  - `OPENAI_BASE_URL=http://127.0.0.1:8000` (ou `8080`)
  - `OPENAI_API_KEY` peut être vide/dummy si le serveur ne vérifie pas.

## Lancer une exploration

```bash
cd $HOME/cfl_watch
export OPENAI_BASE_URL=http://127.0.0.1:8000
bash tools/llm_explore.sh "Ouvre CFL, cherche un trajet Luxembourg -> Arlon"
```

Pendant l'exécution :
- Les dumps XML sont écrits dans `$CFL_TMP_DIR` (par défaut `/sdcard/cfl_watch/tmp`).
- Les snapshots (png/xml) et logs sont stockés sous `/sdcard/cfl_watch`.
- Un fichier `/sdcard/cfl_watch/STOP` arrêtera proprement la boucle.
- `CFL_DRY_RUN=1` permet de tracer sans exécuter les actions adb.

En cas d'erreur, un viewer HTML est généré sous le répertoire de run (`.../viewers/index.html`) pour inspecter les captures et le XML.
