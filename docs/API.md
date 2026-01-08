# CFL Watch – Mini UI API (Bash)

> **Objectif :** écrire des scénarios lisibles, robustes, et maintenables, sans se noyer dans des regex `grep` partout.

Cette “mini API” est une couche de confort au-dessus de vos primitives existantes (`dump_ui`, `wait_dump_grep`, `tap_by_selector`, `wait_results_ready`, etc.).  
Elle centralise 3 problèmes classiques :

- **Avoir un dump UI frais** au moment où on agit.
- **Attendre un état UI** sans timing “au pif”.
- **Rendre le scénario humainement lisible** (“attends écran home”, “tape destination”, etc.).

---

## Table des matières

- [Pré-requis](#pré-requis)
- [Concepts clés](#concepts-clés)
- [Installation / intégration](#installation--intégration)
- [Référence API](#référence-api)
  - [État & cache](#état--cache)
  - [Wait](#wait)
  - [Tap](#tap)
  - [Retry](#retry)
  - [Macros de scénarios](#macros-de-scénarios)
  - [Snapshots](#snapshots)
- [Patterns recommandés](#patterns-recommandés)
- [Erreurs fréquentes](#erreurs-fréquentes)
- [Exemple de scénario complet](#exemple-de-scénario-complet)
- [Extensions suggérées](#extensions-suggérées)
- [Changelog](#changelog)

---

## Pré-requis

Cette API suppose que vous avez déjà :

- `dump_ui` : génère un dump UI et renvoie **le chemin du XML**.
- `wait_dump_grep` : boucle `dump_ui + grep` jusqu’à matcher une regex.
- `resid_regex` : convertit `:id/foo` en pattern `resource-id="…:id/foo"`.
- `tap_by_selector` : trouve des coordonnées dans un dump et tap.
- `wait_results_ready` : attend que la liste de suggestions soit prête.
- `log`, `warn` : logs standard.
- (optionnel) `ui_snap` / `snap_from_dump` selon votre design.

> ⚠️ Avec `set -euo pipefail` : si une fonction retourne non-zéro et n’est pas gérée (`|| true` ou `if`), le script peut s’arrêter. C’est voulu, mais il faut être explicite.

---

## Concepts clés

### 1) `dump_cache`

`dump_cache` est une variable globale qui contient **le chemin du dernier XML** (dump UI) utilisé par l’API.

- Avantage : toutes les actions `tap` utilisent **le même dump** (cohérence).
- Réduction des coûts : vous évitez de dumper 2 fois pour “attendre + taper”.

### 2) “Wait met à jour le cache”

Les fonctions `ui_wait_*` **mettent toujours à jour** `dump_cache` avec un dump qui a matché (ou un fallback `dump_ui`).

### 3) “Tap lit dans le cache”

Les fonctions `ui_tap_*` lisent dans `dump_cache`.  
Donc le pattern recommandé est :

1. `ui_refresh` ou `ui_wait_*`
2. `ui_tap_*`

---

## Installation / intégration

### Option A – Dans le scénario

Copiez le bloc API dans votre script, après les helpers bas niveau (`dump_ui`, `tap_by_selector`, etc.).

### Option B – Module réutilisable (recommandé)

Créez un fichier : `lib/ui_api.sh` avec ces fonctions, puis dans chaque scénario :

```bash
. "$CFL_CODE_DIR/lib/ui_api.sh"
```

---

## Référence API

### État & cache

#### `ui_refresh`

> Prend un dump UI maintenant et met à jour `dump_cache`.

```bash
ui_refresh
```

**Effet :** `dump_cache="$(dump_ui)"`

**Quand l’utiliser :**
- Juste avant une action (`tap`, analyse).
- Après une transition (tap, enter, navigation).

---

## Wait

### `ui_wait_contentdesc <label> <needle> [timeout]`

> Attend qu’un **content-desc** contienne une sous-chaîne.

```bash
ui_wait_contentdesc "destination visible" "destination" 20
```

**Arguments :**
- `label` : nom lisible pour les logs.
- `needle` : sous-chaîne recherchée (non échappée).
- `timeout` (optionnel) : défaut `$WAIT_LONG`.

**Effet :**
- met à jour `dump_cache` avec un dump matchant (ou fallback `dump_ui`)
- log `wait ok: <label>`

**Notes :**
- La recherche est **case-sensitive** via regex telle quelle.
- Si `needle` contient des caractères regex spéciaux, il faut les échapper (voir [Erreurs fréquentes](#erreurs-fréquentes)).

---

### `ui_wait_resourceid <label> <resid> [timeout]`

> Attend qu’un **resource-id** soit présent dans le dump.

```bash
ui_wait_resourceid "home:start field" ":id/input_start" 30
```

**Arguments :**
- `label` : nom loggable.
- `resid` : `:id/...` (suffix-only) ou id complet.
- `timeout` (optionnel) : défaut `$WAIT_LONG`.

**Effet :**
- met à jour `dump_cache`
- log `wait ok: <label>`

---

## Tap

### `ui_tap_contentdesc <label> <needle>`

> Tape un élément dont `content-desc` contient `<needle>`, dans le `dump_cache` courant.

```bash
ui_tap_contentdesc "destination field" "destination"
```

**Pré-requis :** `dump_cache` doit être récent (typiquement via `ui_refresh` ou `ui_wait_*` avant).

---

### `ui_tap_resourceid <label> <resid>`

> Tape un élément identifié par resource-id, dans le `dump_cache` courant.

```bash
ui_tap_resourceid "start field" ":id/input_start"
```

---

## Retry

### `ui_tap_retry <label> [tries] <selectors...>`

> Tente plusieurs fois : refresh + tap.  
> Utile en transition d’écran ou animations.

```bash
ui_tap_retry "destination field" 3   "content-desc=destination"   "content-desc=Select destination"   "resource-id=:id/input_target"
```

**Arguments :**
- `label` : label loggable.
- `tries` : défaut `3`.
- `selectors...` : arguments passés à `ui_tap_any` (voir section [Extensions suggérées](#extensions-suggérées)).

**Comportement :**
- À chaque tentative : `ui_refresh` puis `ui_tap_any`.
- Retourne `0` dès qu’un tap réussit, sinon `1`.

> ⚠️ Cette fonction suppose l’existence de `ui_tap_any`. Si vous ne l’avez pas encore, voir [Extensions suggérées](#extensions-suggérées).

---

## Macros de scénarios

### `ui_wait_screen <screen>`

> Macro “haut niveau” pour des états d’écran standards.

```bash
ui_wait_screen home
ui_wait_screen suggestions
ui_wait_screen search_ready
```

**Écrans supportés (actuels) :**
- `home` : attend `ID_START`
- `suggestions` : appelle `wait_results_ready` puis `ui_refresh`
- `search_ready` : attend le bouton Search (via `ui_wait_search_button`)

**Notes :**
- Cette macro suppose `ID_START`, `ui_wait_resid` et `ui_wait_search_button` disponibles.
- Ajoutez vos écrans ici : c’est le bon endroit pour centraliser les variations d’app (locale / A/B tests).

---

## Snapshots

### `ui_snap_here <tag> [mode]`

> Prend un dump frais, puis fait un snapshot.

```bash
ui_snap_here "03_after_pick_start" "$SNAP_MODE"
```

**Effet :**
- `ui_refresh`
- `ui_snap "$tag" "$mode"`

**Pourquoi c’est propre :**
- Vous capturez l’état réel “maintenant”, pas un vieux dump.

> ⚠️ `ui_snap` n’est pas montré dans votre extrait. Deux options :
> - vous avez déjà `ui_snap` (ou `snap_from_dump`)
> - sinon, implémentez-le (voir [Extensions suggérées](#extensions-suggérées))

---

## Patterns recommandés

### Pattern 1 – Attendre puis taper (sans ID)

```bash
ui_wait_contentdesc "destination visible" "destination"
ui_tap_contentdesc "destination field" "destination"
```

### Pattern 2 – ID stable, fallback content-desc

```bash
ui_refresh
ui_tap_resourceid "start field" ":id/input_start"   || ui_tap_contentdesc "start field" "Select start"
```

### Pattern 3 – Tap en transition (retry)

```bash
ui_tap_retry "destination field" 4   "content-desc=destination"   "content-desc=Select destination"
```

### Pattern 4 – Snapshot “au bon moment”

```bash
ui_snap_here "05_before_search" "$SNAP_MODE"
```

---

## Erreurs fréquentes

### 1) “Ça tape pas” alors que l’élément existe

Cause : `dump_cache` est ancien.  
Fix : utilisez `ui_refresh` ou `ui_wait_*` juste avant.

### 2) `needle` content-desc avec caractères regex

`ui_wait_contentdesc` construit une regex.  
Si `needle` contient `(` `[` `.` `?` etc., ça peut matcher n’importe quoi ou casser le grep.

Solution : échapper `needle` (future amélioration : `ui_wait_contentdesc_literal`).

### 3) `set -e` coupe le scénario

Si `ui_tap_*` échoue (retour non-zéro), et que vous ne gérez pas l’échec, le script peut sortir.

Fix :

```bash
ui_tap_contentdesc ... || true
```

ou :

```bash
if ! ui_tap_contentdesc ...; then
  warn "fallback..."
fi
```

---

## Exemple de scénario complet

```bash
# 1) Home
ui_wait_resourceid "home:start field visible" ":id/input_start" "$WAIT_LONG"
ui_snap_here "01_home" "$SNAP_MODE"

# 2) Start
ui_refresh
ui_tap_resourceid "start field" ":id/input_start"   || ui_tap_contentdesc "start field" "Select start"
maybe type_text "$START_TEXT"

ui_wait_screen suggestions
ui_snap_here "02_start_suggestions" "$SNAP_MODE"
# (puis selection suggestion via vos helpers existants)

# 3) Destination sans ID
ui_wait_contentdesc "destination visible" "destination" "$WAIT_LONG"
ui_tap_contentdesc "destination field" "destination"
maybe type_text "$TARGET_TEXT"

ui_wait_screen suggestions
ui_snap_here "03_destination_suggestions" "$SNAP_MODE"

# 4) Search
ui_wait_screen search_ready
ui_snap_here "04_search_ready" "$SNAP_MODE"
# tap search (id/text) via vos helpers
```

---

## Extensions suggérées

Ce que vous avez déjà est bon, mais voici 3 ajouts qui rendent l’API vraiment “pro” (et diminuent les scripts moches).

### 1) `ui_tap_any` (fallbacks propres)

Permet : `resid:...`, `desc:...`, `text:...`, avec liste de fallbacks.

Usage :

```bash
ui_tap_any "search button"   "resid::id/button_search_default"   "resid::id/button_search"   "text:Rechercher"   "text:Itinéraires"
```

### 2) `ui_wait_any` (attendre une des conditions)

Attendre “destination OU home OU erreur”, puis mettre `dump_cache` à jour.

### 3) `ui_snap_from_cache`

Prendre un screenshot/xml en réutilisant `dump_cache` (zéro redump), si votre infra le permet.

---

## Changelog

- `v0.1` : `ui_refresh`, `ui_wait_*`, `ui_tap_*`, `ui_tap_retry`, `ui_wait_screen`, `ui_snap_here`
