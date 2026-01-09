#!/data/data/com.termux/files/usr/bin/bash
# ui_datetime.sh (CFL WATCH)
#
# But:
#   Piloter le dialog "Date/Heure" de CFL Mobile en mode "humain":
#     - attendre que le TimePicker soit visible
#     - régler la date (via boutons +1 / -1 jour)
#     - régler l'heure (en tapant dans les EditText des NumberPickers)
#     - gérer le mode 12h (AM/PM) sans se faire piéger par l'EditText
#
# Dépendances attendues (dans ton repo / environnement):
#   - ui_wait_resid   : attend un resource-id dans le dump UI
#   - ui_tap_any      : tap via selectors (resid/text/desc)
#   - ui_refresh      : (optionnel) force un dump UI récent
#   - adb             : adb accessible (Termux: pkg install android-tools)
#   - python          : Python dispo (Termux: pkg install python)
#
# Variables d'environnement (optionnelles):
#   UI_DT_DEBUG=1       -> logs debug sur stderr
#   UI_STEP_SLEEP=0.05  -> petites pauses entre actions (stabilité UI)
#   UI_TAP_DELAY=0.06   -> délai après un tap (AM/PM surtout)
#   CFL_TMP_DIR         -> ex: $HOME/.cache/cfl_watch
#   UI_XML              -> pointer un fichier xml précis
#   SNAP_DIR            -> fallback: dernier snapshot *.xml
#
# NOTE IMPORTANT (lib):
#   Ce fichier est typiquement "source" dans d'autres scripts.
#   On évite donc de forcer `set -euo pipefail` quand on est sourcé
#   (sinon tu pollues le shell appelant).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi

# -----------------------------------------------------------------------------
# Logging safe (si ton framework n'a pas déjà log()/warn())
# -----------------------------------------------------------------------------
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[*] %s\n' "$*" >&2; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '[!] %s\n' "$*" >&2; }
fi

_dbg() {
  [[ "${UI_DT_DEBUG:-0}" != "0" ]] || return 0
  printf '[D] %s\n' "$*" >&2
}

# Wrapper "maybe": si ton repo fournit `maybe`, on l'utilise.
# Sinon on exécute directement.
_maybe() {
  if declare -F maybe >/dev/null 2>&1; then
    maybe "$@"
  else
    "$@"
  fi
}

# -----------------------------------------------------------------------------
# XML selection helpers
# -----------------------------------------------------------------------------

# Dernier xml dans SNAP_DIR (si fourni)
_ui_latest_xml() {
  local dir="${SNAP_DIR:-}"
  [[ -n "$dir" ]] || { echo ""; return 0; }
  ls -1t "$dir"/*.xml 2>/dev/null | head -n1 || true
}

# Liste candidates "probables" (ordre = préférence).
# On essaye de prendre un xml qui contient une "needle" (string fixe).
_ui_pick_xml_need() {
  local needle="${1:-}"
  local tmp="${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}"
  local candidates=()
  local f=""

  # 1) UI_XML forcé
  [[ -n "${UI_XML:-}" && -f "${UI_XML:-}" ]] && candidates+=("$UI_XML")

  # 2) dumps live habituels
  f="$tmp/live_dump.xml"; [[ -f "$f" ]] && candidates+=("$f")
  f="$tmp/ui.xml";        [[ -f "$f" ]] && candidates+=("$f")

  # 3) snapshot le plus récent
  f="$(_ui_latest_xml)"; [[ -n "$f" && -f "$f" ]] && candidates+=("$f")

  # Si aucun fichier, tenter un refresh (1 fois) si dispo
  if (( ${#candidates[@]} == 0 )); then
    if declare -F ui_refresh >/dev/null 2>&1; then
      _dbg "No XML candidates. ui_refresh once..."
      ui_refresh || true
      f="$tmp/live_dump.xml"; [[ -f "$f" ]] && candidates+=("$f")
      f="$tmp/ui.xml";        [[ -f "$f" ]] && candidates+=("$f")
      f="$(_ui_latest_xml)"; [[ -n "$f" && -f "$f" ]] && candidates+=("$f")
    fi
  fi

  # Si needle fournie, on choisit le premier xml qui la contient
  if [[ -n "$needle" ]]; then
    for f in "${candidates[@]}"; do
      if grep -Fq "$needle" "$f" 2>/dev/null; then
        echo "$f"
        return 0
      fi
    done
  fi

  # Sinon: premier candidat
  for f in "${candidates[@]}"; do
    echo "$f"
    return 0
  done

  return 1
}

# -----------------------------------------------------------------------------
# ADB input helpers
# -----------------------------------------------------------------------------

_ui_tap_xy() {
  # Tap brut aux coordonnées (pixels écran)
  local x="$1" y="$2"
  _maybe adb shell input tap "$x" "$y"
}

_ui_key() {
  # Envoyer un keyevent Android
  local code="$1"
  _maybe adb shell input keyevent "$code"
}

_adb_text_escape() {
  # adb input text a des règles pénibles:
  # - les espaces se mettent en %s
  # - certains chars spéciaux peuvent casser (selon IME)
  # On reste minimaliste ici (tu envoies surtout "19:40" / "07" etc.)
  local s="$1"
  s="${s// /%s}"
  printf '%s' "$s"
}

_ui_ime_dump() {
  # dumpsys peut échouer / être vide -> jamais de crash
  _maybe adb shell dumpsys input_method 2>/dev/null | tr -d '\r' || true
}

_ui_ime_is_shown() {
  local s="$(_ui_ime_dump)"
  grep -Eq 'm(InputShown|IsInputShown)=true|InputShown=true' <<<"$s"
}

_ui_ime_is_hidden() {
  local s="$(_ui_ime_dump)"
  grep -Eq 'm(InputShown|IsInputShown)=false|InputShown=false|mImeWindowVis=0x0\b|mImeWindowVis=0\b' <<<"$s"
}

_ui_wait_ime_shown() {
  # Attend que le clavier apparaisse (ou soit déjà là)
  local timeout_ms="${UI_IME_SHOW_TIMEOUT_MS:-2000}"   # <-- ton "2 secondes" par défaut
  local poll_ms="${UI_IME_POLL_MS:-80}"
  local min_sleep="${UI_IME_SHOW_MIN_SLEEP:-0.10}"     # laisse finir l'animation

  local sec=$((poll_ms/1000)) ms=$((poll_ms%1000))
  local poll_s="${sec}.$(printf "%03d" "$ms")"

  local waited=0
  while (( waited < timeout_ms )); do
    if _ui_ime_is_shown; then
      sleep "$min_sleep"
      return 0
    fi
    sleep "$poll_s"
    waited=$(( waited + poll_ms ))
  done

  # Fallback: même si on n'a pas détecté, on laisse un mini délai
  sleep "${UI_IME_SHOW_FALLBACK_SLEEP:-0.15}"
  return 0
}

_ui_wait_ime_hidden() {
  # Attend que le clavier disparaisse
  local timeout_ms="${UI_IME_HIDE_TIMEOUT_MS:-2000}"
  local poll_ms="${UI_IME_POLL_MS:-80}"
  local min_sleep="${UI_IME_HIDE_MIN_SLEEP:-0.10}"

  local sec=$((poll_ms/1000)) ms=$((poll_ms%1000))
  local poll_s="${sec}.$(printf "%03d" "$ms")"

  local waited=0
  while (( waited < timeout_ms )); do
    if _ui_ime_is_hidden; then
      sleep "$min_sleep"
      return 0
    fi
    sleep "$poll_s"
    waited=$(( waited + poll_ms ))
  done

  sleep "${UI_IME_HIDE_FALLBACK_SLEEP:-0.15}"
  return 0
}

_ui_type_at() {
  # Cycle sûr:
  # 1) tap -> attendre IME visible
  # 2) input text -> micro pause commit
  # 3) BACK -> attendre IME caché
  local x="$1" y="$2" txt="$3"
  [[ "$x" != "0" && "$y" != "0" ]] || return 1

  local step="${UI_STEP_SLEEP:-0}"

  _ui_tap_xy "$x" "$y"
  (( step > 0 )) && sleep "$step"

  # 1) attendre que le clavier soit là (ton point clé)
  _ui_wait_ime_shown || true

  # 2) taper
  _maybe adb shell input text "$(_adb_text_escape "$txt")"
  sleep "${UI_AFTER_TEXT_SLEEP:-0.08}"   # laisse l'IME "committer"

  # 3) BACK (chez toi: valide + ferme clavier)
  _ui_key 4 || true

  # 4) attendre que le clavier soit vraiment parti avant de re-cliquer ailleurs
  _ui_wait_ime_hidden || true
}

# -----------------------------------------------------------------------------
# Public: dialog presence / OK / presets
# -----------------------------------------------------------------------------

ui_datetime_wait_dialog() {
  # Attendre que le dialog DateTime soit prêt: TimePicker + bouton OK.
  local t="${1:-30}"
  ui_wait_resid "time picker visible" ":id/picker_time" "$t"
  ui_wait_resid "OK button visible" "android:id/button1" "$t"
}

ui_datetime_ok() {
  # Clique sur OK (Android standard: button1)
  ui_tap_any "OK button" "resid:android:id/button1"
}

ui_datetime_preset() {
  # Clique sur les presets CFL (Now / +15m / +1h)
  local preset="${1:-}"
  case "$preset" in
    now)
      ui_tap_any "datetime preset now" \
        "resid:de.hafas.android.cfl:id/button_datetime_forward_1" "text:Now"
      ;;
    15m)
      ui_tap_any "datetime preset +15m" \
        "resid:de.hafas.android.cfl:id/button_datetime_forward_2" "text:In 15"
      ;;
    1h)
      ui_tap_any "datetime preset +1h" \
        "resid:de.hafas.android.cfl:id/button_datetime_forward_3" "text:In 1"
      ;;
    *)
      warn "Unknown preset: $preset"
      return 2
      ;;
  esac
}

# -----------------------------------------------------------------------------
# DATE: lire la date affichée puis +/- jours
# -----------------------------------------------------------------------------

ui_datetime_read_base_ymd() {
  # IMPORTANT:
  #   On lit le texte visible (dd.mm.yyyy) dans le pager date,
  #   pas le content-desc qui peut être en mm.dd.yyyy dans ce dialog.
  local xml
  xml="$(_ui_pick_xml_need 'de.hafas.android.cfl:id/pager_date')" || return 1

  python - <<'PY' "$xml"
import re, sys
from datetime import datetime
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()

def find_node(pred):
  for n in root.iter("node"):
    if pred(n): return n
  return None

pager = find_node(lambda n: n.get("resource-id","") == "de.hafas.android.cfl:id/pager_date")
pat = re.compile(r"\b(\d{2})\.(\d{2})\.(\d{4})\b")

def scan(it):
  for n in it:
    t = (n.get("text","") or "")
    m = pat.search(t)
    if m:
      dd, mm, yyyy = m.group(1), m.group(2), m.group(3)
      d = datetime.strptime(f"{dd}.{mm}.{yyyy}", "%d.%m.%Y").date()
      print(d.isoformat())
      return True
  return False

# pager subtree d'abord (meilleur signal)
if pager is not None and scan(pager.iter("node")):
  sys.exit(0)

# fallback global (rare)
if scan(root.iter("node")):
  sys.exit(0)

sys.exit(1)
PY
}

ui_datetime_set_date_ymd() {
  # Stratégie:
  #   - lire la date actuelle affichée (base)
  #   - calculer diff en jours jusqu'à la target
  #   - taper diff fois "One day later" ou "One day earlier"
  #
  # Format: YYYY-MM-DD
  local ymd="$1"
  [[ "$ymd" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
    warn "Bad DATE_YMD format: '$ymd' (expected YYYY-MM-DD)"
    return 1
  }

  local base
  base="$(ui_datetime_read_base_ymd || true)"
  [[ -n "$base" ]] || base="$(date +%Y-%m-%d)"
  _dbg "date_base=$base target=$ymd"

  local diff
  diff="$(python - <<'PY' "$base" "$ymd"
import sys, datetime
a = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d").date()
b = datetime.datetime.strptime(sys.argv[2], "%Y-%m-%d").date()
print((b-a).days)
PY
)"
  diff="${diff:-0}"

  # Sécurité: si diff énorme, c'est probablement un mauvais parsing
  if (( diff > 4000 || diff < -4000 )); then
    warn "Date diff insane ($diff days). Refusing to spam taps."
    return 1
  fi

  if (( diff > 0 )); then
    local i
    for ((i=0;i<diff;i++)); do
      ui_tap_any "one day later" \
        "resid:de.hafas.android.cfl:id/button_later" \
        "desc:One day later" || true
    done
  elif (( diff < 0 )); then
    diff=$(( -diff ))
    local i
    for ((i=0;i<diff;i++)); do
      ui_tap_any "one day earlier" \
        "resid:de.hafas.android.cfl:id/button_earlier" \
        "desc:One day earlier" || true
    done
  fi
}

# -----------------------------------------------------------------------------
# TIME: parse coords + mode (24h/12h) depuis l'UI XML
# -----------------------------------------------------------------------------

ui_datetime_time_parse_line() {
  # Retourne UNE ligne "k=v" séparée par ';', ex:
  #   TP_MODE=12;H_CUR=11;M_CUR=55;AP_CUR=AM;H_INP_X=...;...
  #
  # Règle clé:
  #   - Pour heure/minute: on tape dans l'EditText (android:id/numberpicker_input)
  #   - Pour AM/PM: on ne tape JAMAIS dans l'EditText (ça déclenche ton bug AM/PM),
  #     on clique sur les boutons "AM" / "PM" si présents.
  local xml
  xml="$(_ui_pick_xml_need 'de.hafas.android.cfl:id/picker_time')" || return 1
  _dbg "time_parse: using xml=$xml"

  python - <<'PY' "$xml"
import sys, re
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()

def parse_bounds(b):
  m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b or "")
  if not m: return None
  return tuple(map(int, m.groups()))

def center(b):
  x1,y1,x2,y2 = b
  return (x1+x2)//2, (y1+y2)//2

def find_node(pred):
  for n in root.iter("node"):
    if pred(n): return n
  return None

tp = find_node(lambda n: n.get("resource-id","")=="de.hafas.android.cfl:id/picker_time")
if tp is None:
  sys.exit(2)

# Collect NumberPickers within picker_time
nps = [c for c in tp.iter("node") if c.get("class","")=="android.widget.NumberPicker"]
if len(nps) < 2:
  sys.exit(3)

def np_x1(np):
  b = parse_bounds(np.get("bounds",""))
  return b[0] if b else 1_000_000

def find_input(np):
  for c in np.iter("node"):
    if c.get("class","")=="android.widget.EditText" and c.get("resource-id","")=="android:id/numberpicker_input":
      return c
  return None

def input_xy_and_txt(np):
  inp = find_input(np)
  if inp is None:
    return None, ""
  b = parse_bounds(inp.get("bounds",""))
  return (center(b) if b else None), (inp.get("text","") or "").strip()

# Sort by x (left->right): typically H | M | AM/PM
nps_sorted = sorted(nps, key=np_x1)

ap_np = None
numeric = []
for np in nps_sorted:
  xy, txt = input_xy_and_txt(np)
  if txt.strip().upper() in ("AM","PM"):
    ap_np = np
  else:
    numeric.append(np)

# Fallback: if heuristic fails, take first two as numeric
if len(numeric) < 2:
  numeric = [np for np in nps_sorted if np is not ap_np][:2]

hour_np, min_np = numeric[0], numeric[1]
h_xy, h_cur = input_xy_and_txt(hour_np)
m_xy, m_cur = input_xy_and_txt(min_np)

tp_mode = "24"
ap_xy = None
ap_cur = ""
ap_am = None
ap_pm = None

if ap_np is not None:
  ap_xy, ap_cur = input_xy_and_txt(ap_np)

  # Capture coords of AM/PM BUTTONS (important: avoid EditText)
  for c in ap_np.iter("node"):
    t = (c.get("text","") or "").strip().upper()
    cls = c.get("class","") or ""
    b = parse_bounds(c.get("bounds",""))
    if not b:
      continue
    if cls == "android.widget.Button":
      if t == "AM": ap_am = center(b)
      if t == "PM": ap_pm = center(b)

  if ap_cur.strip().upper() in ("AM","PM") or ap_am or ap_pm:
    tp_mode = "12"

pairs=[]
def add(k,v):
  if v is None: return
  pairs.append(f"{k}={v}")

add("TP_MODE", tp_mode)
add("H_CUR", h_cur or "0")
add("M_CUR", m_cur or "0")
add("AP_CUR", ap_cur.strip().upper())

if h_xy: add("H_INP_X", h_xy[0]); add("H_INP_Y", h_xy[1])
if m_xy: add("M_INP_X", m_xy[0]); add("M_INP_Y", m_xy[1])
if ap_xy: add("AP_INP_X", ap_xy[0]); add("AP_INP_Y", ap_xy[1])
if ap_am: add("AP_AM_X", ap_am[0]); add("AP_AM_Y", ap_am[1])
if ap_pm: add("AP_PM_X", ap_pm[0]); add("AP_PM_Y", ap_pm[1])

print(";".join(pairs))
PY
}

_ui_apply_kv_line() {
  # Convertit "A=1;B=2" -> variables shell A="1" B="2"
  local line="${1:-}"
  [[ -n "$line" ]] || return 1

  local IFS=';'
  local parts=($line)
  local p k v
  for p in "${parts[@]}"; do
    [[ -n "$p" && "$p" == *"="* ]] || continue
    k="${p%%=*}"
    v="${p#*=}"
    [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    printf -v "$k" '%s' "$v"
  done
}

_ui_timepicker_refresh_and_parse() {
  # Optionnel: forcer un ui_refresh puis re-parse.
  # Utile si tu suspects un xml "vieux" (layout/coords bougent).
  local line=""
  if declare -F ui_refresh >/dev/null 2>&1; then
    ui_refresh || true
  fi
  line="$(ui_datetime_time_parse_line 2>/dev/null || true)"
  [[ -n "$line" ]] || return 1
  _ui_apply_kv_line "$line"
  _dbg "time_reparse: $line"
  return 0
}

_ui_ampm_set() {
  # Force AM/PM en cliquant le BON bouton (pas l'EditText).
  local target="${1:-}"
  local delay="${2:-${UI_TAP_DELAY:-0.06}}"

  [[ "${TP_MODE:-24}" == "12" ]] || return 0
  target="${target^^}"

  [[ "$target" == "AM" || "$target" == "PM" ]] || return 2

  # Si déjà bon, rien à faire
  local cur="${AP_CUR:-}"
  cur="${cur^^}"
  [[ -n "$cur" && "$cur" == "$target" ]] && return 0

  if [[ "$target" == "AM" && "${AP_AM_X:-0}" != "0" ]]; then
    _ui_tap_xy "$AP_AM_X" "$AP_AM_Y"
    sleep "$delay"
    return 0
  fi
  if [[ "$target" == "PM" && "${AP_PM_X:-0}" != "0" ]]; then
    _ui_tap_xy "$AP_PM_X" "$AP_PM_Y"
    sleep "$delay"
    return 0
  fi

  warn "AM/PM: bouton $target introuvable (UI différente ou pas un vrai 12h picker)"
  return 1
}

ui_datetime_set_time_24h() {
  # Régle l'heure depuis une string HH:MM (24h).
  # En mode 12h: conversion en (h12 + AM/PM) puis saisie.
  local hm="${1:-}"

  [[ "$hm" =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || {
    warn "Bad TIME_HM format: '$hm' (expected HH:MM)"
    return 1
  }

  local th="${hm%:*}" tm="${hm#*:}"
  th=$((10#$th))
  tm=$((10#$tm))

  # Valeurs par défaut anti -u
  TP_MODE="24"
  H_CUR="0"; M_CUR="0"; AP_CUR=""
  H_INP_X="0"; H_INP_Y="0"
  M_INP_X="0"; M_INP_Y="0"
  AP_AM_X="0"; AP_AM_Y="0"
  AP_PM_X="0"; AP_PM_Y="0"

  # Parse (avec fallback refresh)
  local line=""
  line="$(ui_datetime_time_parse_line 2>/dev/null || true)"
  if [[ -z "$line" ]]; then
    warn "TimePicker parse failed. Trying refresh+reparse..."
    _ui_timepicker_refresh_and_parse || { warn "TimePicker still not parsable"; return 1; }
  else
    _ui_apply_kv_line "$line"
  fi

  _dbg "time_kv=${line:-parsed_via_refresh}"
  _dbg "time: TP_MODE=$TP_MODE H_INP=($H_INP_X,$H_INP_Y) M_INP=($M_INP_X,$M_INP_Y) AP_CUR=$AP_CUR"

  if [[ "$TP_MODE" == "12" ]]; then
    # Convert 24h -> 12h + AM/PM
    local target_ampm="AM"
    (( th >= 12 )) && target_ampm="PM"
    local th12=$(( th % 12 ))
    (( th12 == 0 )) && th12=12

    # 1) heure (12h)
    _ui_type_at "$H_INP_X" "$H_INP_Y" "$(printf "%d" "$th12")" || {
      warn "Hour typing failed (missing coords?)"
      return 1
    }

    # 2) minutes
    _ui_type_at "$M_INP_X" "$M_INP_Y" "$(printf "%02d" "$tm")" || {
      warn "Minute typing failed (missing coords?)"
      return 1
    }

    # 3) AM/PM via boutons (après saisie, clavier fermé)
    _ui_ampm_set "$target_ampm" || true

  else
    # Mode 24h: saisie directe
    _ui_type_at "$H_INP_X" "$H_INP_Y" "$(printf "%d" "$th")" || {
      warn "Hour typing failed (missing coords?)"
      return 1
    }

    _ui_type_at "$M_INP_X" "$M_INP_Y" "$(printf "%02d" "$tm")" || {
      warn "Minute typing failed (missing coords?)"
      return 1
    }
  fi
}

# -----------------------------------------------------------------------------
# Optional CLI usage (si tu l'exécutes directement)
# -----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # Exemple:
  #   DATE_YMD=2026-01-10 TIME_HM=19:40 bash ui_datetime.sh
  #
  # Ce mode "standalone" n'est pas obligatoire, mais pratique pour tester vite.
  ui_datetime_wait_dialog "${UI_WAIT_TIMEOUT:-30}"

  if [[ -n "${DATE_YMD:-}" ]]; then
    ui_datetime_set_date_ymd "$DATE_YMD"
  fi

  if [[ -n "${TIME_HM:-}" ]]; then
    ui_datetime_set_time_24h "$TIME_HM"
  fi

  # Ne clique OK que si demandé explicitement
  if [[ "${UI_DT_AUTO_OK:-0}" != "0" ]]; then
    ui_datetime_ok
  fi
fi
