#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# ui_datetime.sh (CFL WATCH)
#
# Objectif:
# - Régler date + heure dans le dialog CFL, de façon "humain": TAP sur le champ + SAISIE.
# - Mode 12h (AM/PM) géré: on clique sur le champ AM/PM actif et on tape AM ou PM.
#
# Dépendances (déjà dans ton repo):
#   - ui_wait_resid
#   - ui_tap_any
#   - ui_refresh (utilisé uniquement en fallback)
#   - adb (dans le PATH)
#
# Variables utiles:
#   UI_DT_DEBUG=1     -> logs debug (stderr)
#   CFL_TMP_DIR       -> ex: $HOME/.cache/cfl_watch
#   UI_XML            -> si tu veux forcer un fichier xml
#   SNAP_DIR          -> fallback vers dernier snapshot
#
# Notes:
# - On évite de spam ui_dump à l’intérieur des setters.
# - La validation/commit des NumberPickers via saisie varie selon Android. Ici on fait:
#   tap -> effacer -> input text -> ENTER -> BACK (pour fermer le clavier si besoin)

# ------------------------- fallbacks safe -----------------------------------

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

_maybe() {
  if declare -F maybe >/dev/null 2>&1; then
    maybe "$@"
  else
    "$@"
  fi
}

# ----------------------------- XML picking ----------------------------------

_ui_latest_xml() {
  local dir="${SNAP_DIR:-}"
  [[ -n "$dir" ]] || { echo ""; return 0; }
  ls -1t "$dir"/*.xml 2>/dev/null | head -n1 || true
}

_ui_pick_xml_need() {
  # Pick first XML file that contains needle (fixed string).
  local needle="${1:-}"
  local candidates=()
  local f=""

  [[ -n "${UI_XML:-}" && -f "$UI_XML" ]] && candidates+=("$UI_XML")

  f="${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}/live_dump.xml"
  [[ -f "$f" ]] && candidates+=("$f")

  f="${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}/ui.xml"
  [[ -f "$f" ]] && candidates+=("$f")

  f="$(_ui_latest_xml)"
  [[ -n "${f:-}" && -f "$f" ]] && candidates+=("$f")

  if [[ -n "$needle" ]]; then
    for f in "${candidates[@]}"; do
      if grep -Fq "$needle" "$f" 2>/dev/null; then
        echo "$f"; return 0
      fi
    done
  fi

  for f in "${candidates[@]}"; do
    echo "$f"; return 0
  done

  return 1
}

# ---------------------------- input helpers ---------------------------------

_ui_tap_xy() {
  local x="$1" y="$2"
  _maybe adb shell input tap "$x" "$y"
}

_ui_key() {
  _maybe adb shell input keyevent "$1"
}

_ui_clear_field() {
  # bruteforce: DEL x 8
  local i
  for ((i=0;i<8;i++)); do _ui_key 67; done
}

_ui_type_at() {
  local x="$1" y="$2" txt="$3"
  [[ "$x" != "0" && "$y" != "0" ]] || return 1

  _ui_tap_xy "$x" "$y"
  _ui_key 123 || true         # move end
  _ui_clear_field             # DEL x 8
  _maybe adb shell input text "$txt"

  # IMPORTANT:
  # - PAS de KEYCODE_BACK (4) -> ça ferme le dialog
  # - PAS de KEYCODE_ENTER (66) -> pas nécessaire, on commit en tapant le champ suivant
}

# --------------------------- dialog presence --------------------------------

ui_datetime_wait_dialog() {
  local t="${1:-30}"
  ui_wait_resid "time picker visible" ":id/picker_time" "$t"
  ui_wait_resid "OK button visible" "android:id/button1" "$t"
}

ui_datetime_ok() {
  ui_tap_any "OK button" "resid:android:id/button1" || return 1
}

ui_datetime_preset() {
  local preset="$1"
  case "$preset" in
    now)  ui_tap_any "datetime preset now"  "resid:de.hafas.android.cfl:id/button_datetime_forward_1" "text:Now" ;;
    15m)  ui_tap_any "datetime preset +15m" "resid:de.hafas.android.cfl:id/button_datetime_forward_2" "text:In 15" ;;
    1h)   ui_tap_any "datetime preset +1h"  "resid:de.hafas.android.cfl:id/button_datetime_forward_3" "text:In 1" ;;
    *)    warn "Unknown preset: $preset"; return 2 ;;
  esac
}

# ------------------------------ DATE ----------------------------------------

ui_datetime_read_base_ymd() {
  # IMPORTANT: on lit le texte visible dans le pager (dd.mm.yyyy),
  # pas le content-desc (souvent mm.dd.yyyy dans ce dialog).
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

# pager subtree d'abord
if pager is not None:
  for n in pager.iter("node"):
    t = (n.get("text","") or "")
    m = pat.search(t)
    if m:
      dd, mm, yyyy = m.group(1), m.group(2), m.group(3)
      d = datetime.strptime(f"{dd}.{mm}.{yyyy}", "%d.%m.%Y").date()
      print(d.isoformat()); sys.exit(0)

# fallback global (rare)
for n in root.iter("node"):
  t = (n.get("text","") or "")
  m = pat.search(t)
  if m:
    dd, mm, yyyy = m.group(1), m.group(2), m.group(3)
    d = datetime.strptime(f"{dd}.{mm}.{yyyy}", "%d.%m.%Y").date()
    print(d.isoformat()); sys.exit(0)

sys.exit(1)
PY
}

ui_datetime_set_date_ymd() {
  local ymd="$1"  # YYYY-MM-DD

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

  if (( diff > 0 )); then
    local i
    for ((i=0;i<diff;i++)); do
      ui_tap_any "one day later" \
        "resid:de.hafas.android.cfl:id/button_later" "resid::id/button_later" \
        "desc:One day later" || true
    done
  elif (( diff < 0 )); then
    diff=$(( -diff ))
    local i
    for ((i=0;i<diff;i++)); do
      ui_tap_any "one day earlier" \
        "resid:de.hafas.android.cfl:id/button_earlier" "resid::id/button_earlier" \
        "desc:One day earlier" || true
    done
  fi
}

# ------------------------------ TIME ----------------------------------------

# Retourne UNE ligne KV:
#   TP_MODE=12;H_CUR=11;M_CUR=55;AP_CUR=AM;H_INP_X=...;...;M_INP_X=...;AP_INP_X=...
ui_datetime_time_parse_line() {
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

nps = [c for c in list(tp) if c.tag=="node" and c.get("class","")=="android.widget.NumberPicker"]
if not nps:
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
def input_xy(np):
  inp = find_input(np)
  if inp is None:
    return None, ""
  b = parse_bounds(inp.get("bounds",""))
  return (center(b) if b else None), (inp.get("text","") or "").strip()

nps_sorted = sorted(nps, key=np_x1)

# Detect AM/PM picker by its input text AM/PM
ap_np = None
numeric=[]
for np in nps_sorted:
  xy, txt = input_xy(np)
  if txt.strip().upper() in ("AM","PM"):
    ap_np = np
  else:
    numeric.append(np)

if len(numeric) < 2:
  numeric = [np for np in nps_sorted if np is not ap_np][:2]

hour_np, min_np = numeric[0], numeric[1]

h_xy, h_cur = input_xy(hour_np)
m_xy, m_cur = input_xy(min_np)

tp_mode = "24"
ap_xy = None
ap_cur = ""
ap_am = None
ap_pm = None

if ap_np is not None:
  ap_xy, ap_cur = input_xy(ap_np)

  # NEW: coords des textes AM/PM (bouton + edittext)
  for c in ap_np.iter("node"):
    t = (c.get("text","") or "").strip().upper()
    b = parse_bounds(c.get("bounds",""))
    if not b:
      continue
    if t == "AM":
      ap_am = center(b)
    elif t == "PM":
      ap_pm = center(b)

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

ui_datetime_set_time_24h() {
  local hm="${1:-}"          # HH:MM
  if [[ ! "$hm" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
    warn "Bad TIME_HM format: '$hm' (expected HH:MM)"
    return 1
  fi

  local th="${hm%:*}" tm="${hm#*:}"
  th=$((10#$th)); tm=$((10#$tm))

  local line=""
  line="$(ui_datetime_time_parse_line 2>/dev/null || true)"
  if [[ -z "$line" ]]; then
    warn "TimePicker parse failed. Trying one ui_refresh + re-parse..."
    ui_refresh || true
    line="$(ui_datetime_time_parse_line 2>/dev/null || true)"
  fi
  [[ -n "$line" ]] || { warn "TimePicker still not parsable"; return 1; }

  # defaults (anti -u)
  TP_MODE="24"
  H_CUR="0"
  M_CUR="0"
  AP_CUR=""
  H_INP_X="0"; H_INP_Y="0"
  M_INP_X="0"; M_INP_Y="0"
  AP_INP_X="0"; AP_INP_Y="0"
  AP_AM_X="0"; AP_AM_Y="0"
  AP_PM_X="0"; AP_PM_Y="0"

  _ui_apply_kv_line "$line"

  _dbg "time_kv=$line"
  _dbg "time_parse: TP_MODE=$TP_MODE H_INP=($H_INP_X,$H_INP_Y) M_INP=($M_INP_X,$M_INP_Y) AP_INP=($AP_INP_X,$AP_INP_Y)"

if [[ "$TP_MODE" == "12" ]]; then
  local target_ampm="AM"
  (( th >= 12 )) && target_ampm="PM"
  local th12=$(( th % 12 )); (( th12 == 0 )) && th12=12

  # 1) heure
  _ui_type_at "$H_INP_X" "$H_INP_Y" "$(printf "%d" "$th12")" || {
    warn "Hour typing failed (missing coords?)"
    return 1
  }
  # commit heure -> focus minutes
  _ui_tap_xy "$M_INP_X" "$M_INP_Y"

  # 2) minutes
  _ui_type_at "$M_INP_X" "$M_INP_Y" "$(printf "%02d" "$tm")" || {
    warn "Minute typing failed (missing coords?)"
    return 1
  }

  # 3) enforce AM/PM again (sans clavier)
  if [[ "$target_ampm" == "AM" && "${AP_AM_X:-0}" != "0" ]]; then
    _ui_tap_xy "$AP_AM_X" "$AP_AM_Y"
  elif [[ "$target_ampm" == "PM" && "${AP_PM_X:-0}" != "0" ]]; then
    _ui_tap_xy "$AP_PM_X" "$AP_PM_Y"
  fi

else
  # 24h mode
  _ui_type_at "$H_INP_X" "$H_INP_Y" "$(printf "%d" "$th")" || return 1
  _ui_tap_xy "$M_INP_X" "$M_INP_Y"
  _ui_type_at "$M_INP_X" "$M_INP_Y" "$(printf "%02d" "$tm")" || return 1
fi

}
