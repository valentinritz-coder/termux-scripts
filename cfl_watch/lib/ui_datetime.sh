#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# ui_datetime.sh (CFL WATCH)
# - Depends on your existing libs:
#     - ui_refresh, ui_wait_resid, ui_tap_any
#     - (optional) log, warn, maybe
#
# Goal: set date + time in CFL datetime dialog reliably, WITHOUT extra ui dumps inside setters.
# We parse the same ui.xml that already works for date, and we tap the spinner controls for time.

# ------------------------- tiny fallbacks (safe) -----------------------------

if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[*] %s\n' "$*" >&2; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '[!] %s\n' "$*" >&2; }
fi
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

_ui_pick_xml() {
  local xml=""

  # 1) explicit override
  xml="${UI_XML:-}"
  if [[ -n "${xml:-}" && -f "$xml" ]]; then
    echo "$xml"; return 0
  fi

  # 2) default path used by many ui_refresh implementations
  xml="${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}/ui.xml"
  if [[ -f "$xml" ]]; then
    echo "$xml"; return 0
  fi

  # 3) fallback: latest snapshot
  xml="$(_ui_latest_xml)"
  if [[ -n "${xml:-}" && -f "$xml" ]]; then
    echo "$xml"; return 0
  fi

  return 1
}

# ---------------------------- input helpers ---------------------------------

_ui_tap_xy() {
  local x="$1" y="$2"
  _maybe adb shell input tap "$x" "$y"
}

_ui_swipe_bounds() {
  # bounds "[x1,y1][x2,y2]" + dir inc|dec -> prints "x1 y1 x2 y2 dur"
  local bounds="$1" dir="$2"
  local dur="${3:-180}"

  python - <<'PY' "$bounds" "$dir" "$dur"
import re, sys
b, dir, dur = sys.argv[1], sys.argv[2], int(sys.argv[3])
m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b.strip())
if not m:
  sys.exit(1)
x1,y1,x2,y2 = map(int, m.groups())
cx = (x1+x2)//2
top = y1 + 30
bot = y2 - 30

# Fallback swipe mapping (if tap coords are missing):
# inc -> swipe up (bottom->top), dec -> swipe down (top->bottom)
if dir == "inc":
  print(f"{cx} {bot} {cx} {top} {dur}")
else:
  print(f"{cx} {top} {cx} {bot} {dur}")
PY
}

# --------------------------- dialog presence --------------------------------

ui_datetime_wait_dialog() {
  local t="${1:-30}"

  # TimePicker visible
  ui_wait_resid "time picker visible" ":id/picker_time" "$t"

  # OK button in Android dialog
  ui_wait_resid "OK button visible" "android:id/button1" "$t"
}

ui_datetime_ok() {
  ui_tap_any "OK button" "resid:android:id/button1" || return 1
}

# Preset buttons: now|15m|1h
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
  local xml
  xml="$(_ui_pick_xml)" || return 1

  python - <<'PY' "$xml"
import re, sys
from datetime import datetime

s = open(sys.argv[1], "r", encoding="utf-8", errors="ignore").read()
s = s.replace("\u00A0"," ").replace("\u202F"," ")

# Prefer "Search date:" content-desc if present
m = re.search(r'content-desc="[^"]*Search date:[^"]*"', s)
cands = [m.group(0)] if m else []
cands.append(s)

pat = re.compile(r'\b(\d{2})[./-](\d{2})[./-](\d{4})\b')

for blob in cands:
  m2 = pat.search(blob)
  if not m2:
    continue
  dd, mm, yyyy = m2.group(1), m2.group(2), m2.group(3)
  try:
    d = datetime.strptime(f"{dd}.{mm}.{yyyy}", "%d.%m.%Y").date()
    print(d.isoformat())  # YYYY-MM-DD
    sys.exit(0)
  except Exception:
    pass

sys.exit(1)
PY
}

ui_datetime_set_date_ymd() {
  local ymd="$1"  # YYYY-MM-DD

  # Base = date displayed in the dialog (fallback: system date)
  local base
  base="$(ui_datetime_read_base_ymd || true)"
  [[ -n "$base" ]] || base="$(date +%Y-%m-%d)"

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

# Parse spinner TimePicker once from the SAME ui.xml.
# Outputs bash vars:
#   TP_MODE=12|24
#   H_CUR, M_CUR, AP_CUR
#   H_INC_X/Y H_DEC_X/Y, M_INC_X/Y M_DEC_X/Y
#   H_BOUNDS, M_BOUNDS (fallback swipes)
#   AP_AM_X/Y, AP_PM_X/Y (if 12h)
ui_datetime_time_parse_vars() {
  local xml
  xml="$(_ui_pick_xml)" || return 1

  python - <<'PY' "$xml"
import sys, re
import xml.etree.ElementTree as ET

xml_path = sys.argv[1]
root = ET.parse(xml_path).getroot()

def parse_bounds(b):
  m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b or "")
  if not m: return None
  x1,y1,x2,y2 = map(int, m.groups())
  return x1,y1,x2,y2

def center(b):
  x1,y1,x2,y2 = b
  return (x1+x2)//2, (y1+y2)//2

def find_node(pred):
  for n in root.iter("node"):
    if pred(n): return n
  return None

tp = find_node(lambda n: n.get("resource-id","")=="de.hafas.android.cfl:id/picker_time"
                        and n.get("class","")=="android.widget.TimePicker")
if tp is None:
  sys.exit(2)

nps = [c for c in list(tp) if c.tag=="node" and c.get("class","")=="android.widget.NumberPicker"]
if len(nps) < 2:
  sys.exit(3)

def np_value(np):
  for c in np.iter("node"):
    if c.get("class","")=="android.widget.EditText" and c.get("resource-id","")=="android:id/numberpicker_input":
      return (c.get("text","") or "").strip()
  return ""

def child_xy(np, idx):
  kids = [c for c in list(np) if c.tag=="node"]
  if len(kids) <= idx: return None
  b = parse_bounds(kids[idx].get("bounds",""))
  return center(b) if b else None

def np_bounds(np):
  b = parse_bounds(np.get("bounds",""))
  return np.get("bounds","") if b else ""

# Hour
h_cur = np_value(nps[0]) or "0"
h_dec = child_xy(nps[0], 0)   # previous
h_inc = child_xy(nps[0], 2)   # next
h_bounds = np_bounds(nps[0])

# Minute
m_cur = np_value(nps[1]) or "0"
m_dec = child_xy(nps[1], 0)
m_inc = child_xy(nps[1], 2)
m_bounds = np_bounds(nps[1])

# AM/PM (optional)
tp_mode = "24"
ap_cur = ""
ap_am = ap_pm = None
if len(nps) >= 3:
  ap_cur = (np_value(nps[2]) or "").strip().upper()
  for c in nps[2].iter("node"):
    t = ((c.get("text","") or "")).strip().upper()
    b = parse_bounds(c.get("bounds",""))
    if not b: continue
    if t == "AM": ap_am = center(b)
    if t == "PM": ap_pm = center(b)
  if ap_cur in ("AM","PM") or ap_am or ap_pm:
    tp_mode = "12"

print(f"TP_MODE={tp_mode}")
print(f"H_CUR={h_cur}")
print(f"M_CUR={m_cur}")
print(f"AP_CUR='{ap_cur}'")
print(f"H_BOUNDS='{h_bounds}'")
print(f"M_BOUNDS='{m_bounds}'")

if h_dec: print(f"H_DEC_X={h_dec[0]}\nH_DEC_Y={h_dec[1]}")
if h_inc: print(f"H_INC_X={h_inc[0]}\nH_INC_Y={h_inc[1]}")
if m_dec: print(f"M_DEC_X={m_dec[0]}\nM_DEC_Y={m_dec[1]}")
if m_inc: print(f"M_INC_X={m_inc[0]}\nM_INC_Y={m_inc[1]}")

if ap_am: print(f"AP_AM_X={ap_am[0]}\nAP_AM_Y={ap_am[1]}")
if ap_pm: print(f"AP_PM_X={ap_pm[0]}\nAP_PM_Y={ap_pm[1]}")
PY
}

ui_datetime_set_time_24h() {
  local hm="$1"          # HH:MM
  local th="${hm%:*}" tm="${hm#*:}"

  log "hm='$hm'"
  log "th_raw='$th' tm_raw='$tm'"

  # sanity: évite crash si hm vide ou format foireux
  if [[ ! "$hm" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
    warn "Bad time format: '$hm' (expected HH:MM)"
    return 1
  fi

  th=$((10#$th))
  tm=$((10#$tm))

  log "th=$th tm=$tm"
  
  local out
  out="$(ui_datetime_time_parse_vars)" || { warn "TimePicker not found"; return 1; }
  eval "$out"

  # Defaults anti set -u
  : "${TP_MODE:=24}" "${H_CUR:=0}" "${M_CUR:=0}" "${AP_CUR:=}"
  : "${H_INC_X:=0}" "${H_INC_Y:=0}" "${H_DEC_X:=0}" "${H_DEC_Y:=0}"
  : "${M_INC_X:=0}" "${M_INC_Y:=0}" "${M_DEC_X:=0}" "${M_DEC_Y:=0}"
  : "${H_BOUNDS:=}" "${M_BOUNDS:=}"
  : "${AP_AM_X:=0}" "${AP_AM_Y:=0}" "${AP_PM_X:=0}" "${AP_PM_Y:=0}"

  local TAP_DELAY="${TAP_DELAY:-0.02}"

  _inc_hour() {
    if [[ "$H_INC_X" -ne 0 ]]; then _ui_tap_xy "$H_INC_X" "$H_INC_Y"
    elif [[ -n "$H_BOUNDS" ]]; then _maybe adb shell input swipe $(_ui_swipe_bounds "$H_BOUNDS" inc 180) || true
    fi
    sleep "$TAP_DELAY"
  }
  _dec_hour() {
    if [[ "$H_DEC_X" -ne 0 ]]; then _ui_tap_xy "$H_DEC_X" "$H_DEC_Y"
    elif [[ -n "$H_BOUNDS" ]]; then _maybe adb shell input swipe $(_ui_swipe_bounds "$H_BOUNDS" dec 180) || true
    fi
    sleep "$TAP_DELAY"
  }
  _inc_min() {
    if [[ "$M_INC_X" -ne 0 ]]; then _ui_tap_xy "$M_INC_X" "$M_INC_Y"
    elif [[ -n "$M_BOUNDS" ]]; then _maybe adb shell input swipe $(_ui_swipe_bounds "$M_BOUNDS" inc 180) || true
    fi
    sleep "$TAP_DELAY"
  }
  _dec_min() {
    if [[ "$M_DEC_X" -ne 0 ]]; then _ui_tap_xy "$M_DEC_X" "$M_DEC_Y"
    elif [[ -n "$M_BOUNDS" ]]; then _maybe adb shell input swipe $(_ui_swipe_bounds "$M_BOUNDS" dec 180) || true
    fi
    sleep "$TAP_DELAY"
  }

  local i

  if [[ "$TP_MODE" == "12" ]]; then
    # Convert 24h -> 12h + AM/PM
    local target_ampm="AM"
    (( th >= 12 )) && target_ampm="PM"
    local th12=$(( th % 12 )); (( th12 == 0 )) && th12=12

    # Hours wrap 12: use 0..11 ring where 12 -> 0
    local curH=$((10#${H_CUR}))
    local tgtH=$((10#${th12}))
    local cur0=$((curH % 12))
    local tgt0=$((tgtH % 12))
    local fwd=$(((tgt0 - cur0 + 12) % 12))
    local bwd=$(((cur0 - tgt0 + 12) % 12))

    if (( fwd <= bwd )); then
      for ((i=0;i<fwd;i++)); do _inc_hour; done
    else
      for ((i=0;i<bwd;i++)); do _dec_hour; done
    fi

    # Minutes wrap 60
    local curM=$((10#${M_CUR}))
    local tgtM=$tm
    fwd=$(((tgtM - curM + 60) % 60))
    bwd=$(((curM - tgtM + 60) % 60))

    if (( fwd <= bwd )); then
      for ((i=0;i<fwd;i++)); do _inc_min; done
    else
      for ((i=0;i<bwd;i++)); do _dec_min; done
    fi

    # Enforce AM/PM by direct tap if available
    if [[ "$target_ampm" == "AM" && "$AP_AM_X" -ne 0 ]]; then
      _ui_tap_xy "$AP_AM_X" "$AP_AM_Y"
    elif [[ "$target_ampm" == "PM" && "$AP_PM_X" -ne 0 ]]; then
      _ui_tap_xy "$AP_PM_X" "$AP_PM_Y"
    fi

  else
    # 24h mode
    local curH=$((10#${H_CUR}))
    local tgtH=$th
    local fwd=$(((tgtH - curH + 24) % 24))
    local bwd=$(((curH - tgtH + 24) % 24))

    if (( fwd <= bwd )); then
      for ((i=0;i<fwd;i++)); do _inc_hour; done
    else
      for ((i=0;i<bwd;i++)); do _dec_hour; done
    fi

    local curM=$((10#${M_CUR}))
    local tgtM=$tm
    fwd=$(((tgtM - curM + 60) % 60))
    bwd=$(((curM - tgtM + 60) % 60))

    if (( fwd <= bwd )); then
      for ((i=0;i<fwd;i++)); do _inc_min; done
    else
      for ((i=0;i<bwd;i++)); do _dec_min; done
    fi
  fi
}
