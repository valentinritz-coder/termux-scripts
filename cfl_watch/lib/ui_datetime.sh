#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Requires: log/warn/maybe (common.sh), ui_refresh/ui_wait_resid/ui_tap_any (ui_* libs)
# Uses python to parse latest UI XML from $SNAP_DIR.

_ui_latest_xml() {
  ls -1t "$SNAP_DIR"/*.xml 2>/dev/null | head -n1 || true
}

ui_tp_read_vars() {
  local xml="${UI_XML:-}"

  # Fallback: dernier xml du SNAP_DIR si UI_XML pas dispo
  [[ -n "${xml:-}" && -f "$xml" ]] || xml="$(_ui_latest_xml)"

  [[ -n "${xml:-}" && -f "$xml" ]] || return 1

  python - <<'PY' "$xml"
import sys, xml.etree.ElementTree as ET

xml_path = sys.argv[1]
root = ET.parse(xml_path).getroot()

def find(node, rid):
  for el in node.iter("node"):
    if el.attrib.get("resource-id","") == rid:
      return el
  return None

tp = find(root, "de.hafas.android.cfl:id/picker_time")
if tp is None:
  sys.exit(1)

# Collect NumberPickers inside TimePicker (hour, minute, ampm)
nps = [ch for ch in tp.findall("node") if ch.attrib.get("class") == "android.widget.NumberPicker"]

bounds = []
vals = []
for np in nps:
  bounds.append(np.attrib.get("bounds",""))
  v = None
  for el in np.iter("node"):
    if el.attrib.get("class") == "android.widget.EditText" and el.attrib.get("resource-id") == "android:id/numberpicker_input":
      v = (el.attrib.get("text") or "").strip()
      break
  vals.append(v or "")

# Heuristics: hour/min are numeric, ampm is AM/PM if present
hour = ""
minute = ""
ampm = ""
for v in vals:
  if v.upper() in ("AM","PM"):
    ampm = v.upper()
  elif v.isdigit():
    if hour == "":
      hour = v
    elif minute == "":
      minute = v

mode = "12" if ampm else "24"

print(f"TP_MODE={mode}")
print(f"TP_HOUR={hour or 0}")
print(f"TP_MIN={minute or 0}")
print(f"TP_AMPM='{ampm}'")

# Bounds mapping by index: 0=hour,1=minute,2=ampm (if exists)
for i,b in enumerate(bounds):
  print(f"TP_BOUNDS_{i}='{b}'")
PY
}

ui_tp_eval_vars() {
  local out
  out="$(ui_tp_read_vars)" || return 1

  # Nettoie d'éventuels \r (Windows/adb)
  out="$(printf "%s\n" "$out" | sed 's/\r$//')"

  eval "$out"

  # Défauts pour éviter set -u qui t’explose à la figure
  : "${TP_MODE:=}" "${TP_HOUR:=0}" "${TP_MIN:=0}" "${TP_AMPM:=}" \
    "${TP_BOUNDS_0:=}" "${TP_BOUNDS_1:=}" "${TP_BOUNDS_2:=}"
}

_ui_center_from_bounds() {
  # bounds like: [232,671][408,1166]  -> echo "320 918"
  python - <<'PY' "$1"
import re, sys
m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', sys.argv[1].strip())
x1,y1,x2,y2 = map(int, m.groups())
print((x1+x2)//2, (y1+y2)//2)
PY
}

_ui_swipe_in_bounds() {
  # $1=bounds, $2=up|down, $3=duration(ms)
  local bounds="$1" dir="$2" dur="${3:-180}"

  python - <<'PY' "$bounds" "$dir" "$dur"
import re, sys
b, dir, dur = sys.argv[1], sys.argv[2], int(sys.argv[3])
m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b.strip())
x1,y1,x2,y2 = map(int, m.groups())
cx = (x1+x2)//2
top = y1 + 30
bot = y2 - 30

if dir == "up":
  # swipe up: start near bottom -> end near top
  print(f"{cx} {bot} {cx} {top} {dur}")
else:
  print(f"{cx} {top} {cx} {bot} {dur}")
PY
}

ui_datetime_lock_dialog_xml() {
  local c1="${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}/ui.xml"
  local c2="$(_ui_latest_xml)"

  local f=""
  for f in "$c1" "$c2"; do
    [[ -n "${f:-}" && -f "$f" ]] || continue
    if grep -q 'de\.hafas\.android\.cfl:id/picker_time' "$f"; then
      export UI_XML="$f"
      return 0
    fi
  done
  return 1
}

_ui_tp_swipe() {
  # $1=index (0 hour,1 min,2 ampm), $2=up|down
  local idx="$1" dir="$2"
  local b_var="TP_BOUNDS_${idx}"
  local b="${!b_var:-}"
  [[ -n "$b" ]] || return 1

  local args
  args="$(_ui_swipe_in_bounds "$b" "$dir" 180)" || return 1
  adb shell input swipe $args
}

_ui_tp_calibrate_inc_dir() {
  # Determine whether "swipe up" increases or decreases hour.
  # Sets global TP_INC_DIR=up|down
  TP_INC_DIR="${TP_INC_DIR:-}"

  [[ -n "$TP_INC_DIR" ]] && return 0

  ui_refresh
  ui_tp_eval_vars || return 1
  local h0="$TP_HOUR"
  # try swipe up once
  _ui_tp_swipe 0 up || return 1
  ui_refresh
  ui_tp_eval_vars || return 1
  local h1="$TP_HOUR"

  # If no change, try a bigger swipe (some devices are picky)
  if [[ "$h1" == "$h0" ]]; then
    _ui_tp_swipe 0 up || true
    ui_refresh
    ui_tp_eval_vars || return 1
    h1="$TP_HOUR"
  fi

  # Decide with wrap rules
  if [[ "$TP_MODE" == "12" ]]; then
    local expected=$(( (h0 % 12) + 1 ))   # 12->1
    if [[ "$h1" == "$expected" ]]; then
      TP_INC_DIR="up"
    else
      TP_INC_DIR="down"
    fi
  else
    local expected=$(( (h0 + 1) % 24 ))
    if [[ "$h1" == "$expected" ]]; then
      TP_INC_DIR="up"
    else
      TP_INC_DIR="down"
    fi
  fi

  # Undo the test step so we don't drift (one step opposite)
  if [[ "$TP_INC_DIR" == "up" ]]; then
    _ui_tp_swipe 0 down || true
  else
    _ui_tp_swipe 0 up || true
  fi
  ui_refresh
}

_ui_tp_step_inc() { # idx
  [[ "${TP_INC_DIR:-up}" == "up" ]] && _ui_tp_swipe "$1" up || _ui_tp_swipe "$1" down
}
_ui_tp_step_dec() { # idx
  [[ "${TP_INC_DIR:-up}" == "up" ]] && _ui_tp_swipe "$1" down || _ui_tp_swipe "$1" up
}

_ui_tp_set_numeric_wrap() {
  # $1=idx (0 hour, 1 min), $2=current, $3=target, $4=mod (12/24/60)
  local idx="$1" cur="$2" tgt="$3" mod="$4"

  cur="${cur:-0}"
  tgt="${tgt:-0}"
  
  # normalize ints
  cur=$((10#$cur))
  tgt=$((10#$tgt))

  local up_steps=$(( (tgt - cur + mod) % mod ))
  local down_steps=$(( (cur - tgt + mod) % mod ))

  # pick minimal
  if (( up_steps <= down_steps )); then
    local i
    for ((i=0;i<up_steps;i++)); do _ui_tp_step_inc "$idx" || true; done
  else
    local i
    for ((i=0;i<down_steps;i++)); do _ui_tp_step_dec "$idx" || true; done
  fi
}

_ui_tp_set_ampm() {
  # $1=target AM/PM, returns 0 if ok
  local target="$1"
  [[ -z "$target" ]] && return 0

  ui_refresh
  ui_tp_eval_vars || return 1
  [[ "$TP_MODE" == "12" ]] || return 0

  if [[ "$TP_AMPM" == "$target" ]]; then
    return 0
  fi

  # One swipe toggles, but direction can vary. Try inc then recheck, else dec.
  _ui_tp_step_inc 2 || true
  ui_refresh
  ui_tp_eval_vars || return 1
  [[ "$TP_AMPM" == "$target" ]] && return 0

  _ui_tp_step_dec 2 || true
  ui_refresh
  ui_tp_eval_vars || return 1
  [[ "$TP_AMPM" == "$target" ]]
}

ui_tp_parse_once() {
  local xml="${UI_XML:-${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}/ui.xml}"
  [[ -f "$xml" ]] || return 1

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

tp = find_node(lambda n: n.get("resource-id","")=="de.hafas.android.cfl:id/picker_time" and n.get("class","")=="android.widget.TimePicker")
if tp is None:
  sys.exit(2)

nps = [c for c in list(tp) if c.tag=="node" and c.get("class","")=="android.widget.NumberPicker"]

# helper: current value + up/down coords from child buttons
def np_info(np):
  kids = [c for c in list(np) if c.tag=="node"]
  inp = None
  for c in kids:
    if c.get("class","")=="android.widget.EditText" and c.get("resource-id","")=="android:id/numberpicker_input":
      inp = c
      break
  cur = (inp.get("text","") if inp is not None else "").strip()

  up_xy = down_xy = None
  # hour/min have 3 kids: [up button, input, down button]
  if len(kids) >= 1 and kids[0].get("bounds"):
    b = parse_bounds(kids[0].get("bounds"))
    if b: up_xy = center(b)
  if len(kids) >= 3 and kids[2].get("bounds"):
    b = parse_bounds(kids[2].get("bounds"))
    if b: down_xy = center(b)

  return cur, up_xy, down_xy, kids

# Hour / Minute
h_cur=h_up=h_down=None
m_cur=m_up=m_down=None
ap_cur=""
ap_am_xy=None
ap_pm_xy=None

if len(nps) >= 1:
  h_cur, h_up, h_down, _ = np_info(nps[0])
if len(nps) >= 2:
  m_cur, m_up, m_down, _ = np_info(nps[1])

mode="24"
if len(nps) >= 3:
  ap_cur, ap_up, ap_down, kids = np_info(nps[2])
  ap_cur = (ap_cur or "").strip().upper()
  # Find direct tap coords for AM / PM by text
  for c in kids:
    t = (c.get("text","") or "").strip().upper()
    b = parse_bounds(c.get("bounds",""))
    if not b: continue
    if t == "AM": ap_am_xy = center(b)
    if t == "PM": ap_pm_xy = center(b)
  if ap_cur in ("AM","PM") or ap_am_xy or ap_pm_xy:
    mode="12"

print(f"TP_MODE={mode}")
print(f"H_CUR={h_cur or 0}")
print(f"M_CUR={m_cur or 0}")

if h_up:   print(f"H_DEC_X={h_up[0]}\nH_DEC_Y={h_up[1]}")
if h_down: print(f"H_INC_X={h_down[0]}\nH_INC_Y={h_down[1]}")
if m_up:   print(f"M_DEC_X={m_up[0]}\nM_DEC_Y={m_up[1]}")
if m_down: print(f"M_INC_X={m_down[0]}\nM_INC_Y={m_down[1]}")

if mode=="12":
  print(f"AP_CUR={ap_cur or ''}")
  if ap_am_xy: print(f"AP_AM_X={ap_am_xy[0]}\nAP_AM_Y={ap_am_xy[1]}")
  if ap_pm_xy: print(f"AP_PM_X={ap_pm_xy[0]}\nAP_PM_Y={ap_pm_xy[1]}")
PY
}

# Parse the datetime dialog from latest xml and print bash vars:
# H_CUR, M_CUR, AP_CUR (optional)
# H_UP_XY, H_DOWN_XY, M_UP_XY, M_DOWN_XY, AP_TAP_XY (optional)
# DATE_DDMMYYYY, EARLIER_XY, LATER_XY
_ui_dt_parse() {
  local xml="$(_ui_latest_xml)"
  [ -n "${xml:-}" ] || { echo "ERR=NO_XML"; return 0; }

  python - <<'PY' "$xml"
import re, sys
import xml.etree.ElementTree as ET

xml_path = sys.argv[1]
tree = ET.parse(xml_path)
root = tree.getroot()

def parse_bounds(b):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b or "")
    if not m:
        return None
    x1,y1,x2,y2 = map(int, m.groups())
    return x1,y1,x2,y2

def center(bounds):
    x1,y1,x2,y2 = bounds
    return (x1+x2)//2, (y1+y2)//2

def find_node(pred):
    for n in root.iter('node'):
        if pred(n):
            return n
    return None

def find_nodes(pred):
    out=[]
    for n in root.iter('node'):
        if pred(n):
            out.append(n)
    return out

def children_nodes(n):
    return [c for c in list(n) if c.tag=='node']

# -------- TimePicker / NumberPickers --------
tp = find_node(lambda n: n.get('resource-id','') == 'de.hafas.android.cfl:id/picker_time' and n.get('class','') == 'android.widget.TimePicker')
if tp is None:
    print("ERR=NO_TIMEPICKER")
else:
    nps = [c for c in children_nodes(tp) if c.get('class','') == 'android.widget.NumberPicker']
    # Expect: hour, minute, am/pm
    def np_info(np):
        kids = children_nodes(np)
        # Up button often index 0, down button often index 2 (may be missing for AM/PM)
        up_btn = None
        down_btn = None
        inp = None
        for c in kids:
            cls = c.get('class','')
            rid = c.get('resource-id','')
            if cls == 'android.widget.EditText' and rid == 'android:id/numberpicker_input':
                inp = c
        if len(kids) >= 1:
            up_btn = kids[0]
        if len(kids) >= 3:
            down_btn = kids[2]
        cur = (inp.get('text','') if inp is not None else '').strip()
        up_xy = center(parse_bounds(up_btn.get('bounds',''))) if up_btn is not None and parse_bounds(up_btn.get('bounds','')) else None
        down_xy = center(parse_bounds(down_btn.get('bounds',''))) if down_btn is not None and parse_bounds(down_btn.get('bounds','')) else None
        inp_xy = center(parse_bounds(inp.get('bounds',''))) if inp is not None and parse_bounds(inp.get('bounds','')) else None
        up_txt = (up_btn.get('text','') or '').strip() if up_btn is not None else ''
        return cur, up_xy, down_xy, inp_xy, up_txt

    if len(nps) >= 1:
        h_cur, h_up, h_down, h_inp, h_up_txt = np_info(nps[0])
        if h_cur: print(f"H_CUR={h_cur}")
        if h_up: print(f"H_UP_X={h_up[0]}\nH_UP_Y={h_up[1]}")
        if h_down: print(f"H_DOWN_X={h_down[0]}\nH_DOWN_Y={h_down[1]}")

    if len(nps) >= 2:
        m_cur, m_up, m_down, m_inp, m_up_txt = np_info(nps[1])
        if m_cur: print(f"M_CUR={m_cur}")
        if m_up: print(f"M_UP_X={m_up[0]}\nM_UP_Y={m_up[1]}")
        if m_down: print(f"M_DOWN_X={m_down[0]}\nM_DOWN_Y={m_down[1]}")

    if len(nps) >= 3:
        ap_cur, ap_up, ap_down, ap_inp, ap_other = np_info(nps[2])
        # For AM/PM picker: current is in input, "other" often in up button text
        if ap_cur: print(f"AP_CUR={ap_cur}")
        # Best tap target: if up button exists, tap it (toggles to the other value)
        # We'll expose both
        if ap_up: print(f"AP_UP_X={ap_up[0]}\nAP_UP_Y={ap_up[1]}")
        if ap_inp: print(f"AP_INP_X={ap_inp[0]}\nAP_INP_Y={ap_inp[1]}")
        if ap_other: print(f"AP_OTHER={ap_other}")

# -------- Date controls --------
earlier = find_node(lambda n: n.get('resource-id','') == 'de.hafas.android.cfl:id/button_earlier')
later   = find_node(lambda n: n.get('resource-id','') == 'de.hafas.android.cfl:id/button_later')

def emit_xy(prefix, node):
    b = parse_bounds(node.get('bounds','')) if node is not None else None
    if b:
        x,y = center(b)
        print(f"{prefix}_X={x}\n{prefix}_Y={y}")

if earlier: emit_xy("EARLIER", earlier)
if later:   emit_xy("LATER", later)

pager = find_node(lambda n: n.get('resource-id','') == 'de.hafas.android.cfl:id/pager_date')
date_txt = ""
if pager is not None:
    # find first TextView under pager that contains dd.mm.yyyy
    for n in pager.iter('node'):
        t = (n.get('text','') or '')
        if re.search(r"\b\d{2}\.\d{2}\.\d{4}\b", t):
            date_txt = t
            break

m = re.search(r"(\d{2}\.\d{2}\.\d{4})", date_txt)
if m:
    print(f"DATE_DDMMYYYY={m.group(1)}")
PY
}

_ui_eval_vars() {
  # shellcheck disable=SC2046
  eval "$(_ui_dt_parse | sed 's/\r$//')"
}

_ui_tap_xy() {
  local x="$1" y="$2"
  # If your repo already has tap(), replace this line by: maybe tap "$x" "$y"
  maybe adb shell input tap "$x" "$y"
}

# Convert 24h to (hour12, ampm)
_ui_to_12h() {
  local hh="$1"
  local ap="AM"
  local h12="$hh"
  if (( hh == 0 )); then h12=12; ap="AM"
  elif (( hh < 12 )); then h12=hh; ap="AM"
  elif (( hh == 12 )); then h12=12; ap="PM"
  else h12=$((hh-12)); ap="PM"
  fi
  printf "%s %s" "$h12" "$ap"
}

# Step a numeric NumberPicker to target using up/down buttons
_ui_np_step_to() {
  local name="$1" cur="$2" target="$3" min="$4" max="$5"
  local upx="$6" upy="$7" downx="$8" downy="$9"

  # sanitize
  cur="${cur#0}"; target="${target#0}"
  [ -n "${cur:-}" ] && [ -n "${target:-}" ] || { warn "$name: missing cur/target"; return 1; }

  local range=$((max - min + 1))
  local curN=$((cur))
  local tgtN=$((target))
  (( curN < min )) && curN=$min
  (( curN > max )) && curN=$max
  (( tgtN < min )) && tgtN=$min
  (( tgtN > max )) && tgtN=$max

  # forward = increments (down button shows next value in your XML)
  local fwd=$(((tgtN - curN + range) % range))
  local bwd=$(((curN - tgtN + range) % range))

  if (( fwd <= bwd )); then
    local i
    for ((i=0;i<fwd;i++)); do _ui_tap_xy "$downx" "$downy"; done
  else
    local i
    for ((i=0;i<bwd;i++)); do _ui_tap_xy "$upx" "$upy"; done
  fi
}

ui_datetime_wait_dialog() {
  local t="${1:-30}"

  # TimePicker dialog
  ui_wait_resid "time picker visible" ":id/picker_time" "$t"

  # TimePicker dialog
  ui_wait_resid "date pager visible" ":id/pager_date" "$t"
  
  # OK button in Android dialog
  ui_wait_resid "OK button visible" "android:id/button1" "$t"
}

ui_datetime_time_parse_vars() {
  local xml="${UI_XML:-${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}/ui.xml}"
  [[ -f "$xml" ]] || return 1

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
      return (c.get("text","") or "").strip(), c
  return "", None

def np_btn_xy(np, idx):
  kids = [c for c in list(np) if c.tag=="node"]
  if len(kids) <= idx: return None
  b = parse_bounds(kids[idx].get("bounds",""))
  return center(b) if b else None

# Hour NP (0): idx0=decrement (prev), idx2=increment (next)
h_cur, _ = np_value(nps[0])
h_dec = np_btn_xy(nps[0], 0)
h_inc = np_btn_xy(nps[0], 2)

# Minute NP (1)
m_cur, _ = np_value(nps[1])
m_dec = np_btn_xy(nps[1], 0)
m_inc = np_btn_xy(nps[1], 2)

# AM/PM NP (2) optional
tp_mode = "24"
ap_cur = ""
ap_am = ap_pm = None
if len(nps) >= 3:
  ap_cur, _ = np_value(nps[2])
  ap_cur = (ap_cur or "").strip().upper()
  # find tap centers for AM and PM by text
  for c in nps[2].iter("node"):
    t = ((c.get("text","") or "")).strip().upper()
    b = parse_bounds(c.get("bounds",""))
    if not b: continue
    if t == "AM": ap_am = center(b)
    if t == "PM": ap_pm = center(b)
  if ap_cur in ("AM","PM") or ap_am or ap_pm:
    tp_mode = "12"

print(f"TP_MODE={tp_mode}")
print(f"H_CUR={h_cur or 0}")
print(f"M_CUR={m_cur or 0}")
print(f"AP_CUR='{ap_cur}'")

if h_dec: print(f"H_DEC_X={h_dec[0]}\nH_DEC_Y={h_dec[1]}")
if h_inc: print(f"H_INC_X={h_inc[0]}\nH_INC_Y={h_inc[1]}")
if m_dec: print(f"M_DEC_X={m_dec[0]}\nM_DEC_Y={m_dec[1]}")
if m_inc: print(f"M_INC_X={m_inc[0]}\nM_INC_Y={m_inc[1]}")

if ap_am: print(f"AP_AM_X={ap_am[0]}\nAP_AM_Y={ap_am[1]}")
if ap_pm: print(f"AP_PM_X={ap_pm[0]}\nAP_PM_Y={ap_pm[1]}")
PY
}

# Preset buttons: now|15m|1h
ui_datetime_preset() {
  local preset="$1"
  case "$preset" in
    now)  ui_tap_any "datetime preset now"  "resid:de.hafas.android.cfl:id/button_datetime_forward_1" || return 1 ;;
    15m)  ui_tap_any "datetime preset +15m" "resid:de.hafas.android.cfl:id/button_datetime_forward_2" || return 1 ;;
    1h)   ui_tap_any "datetime preset +1h"  "resid:de.hafas.android.cfl:id/button_datetime_forward_3" || return 1 ;;
    *)    warn "Unknown preset: $preset"; return 2 ;;
  esac
  ui_refresh
}


ui_datetime_time_parse_vars() {
  local xml="${UI_XML:-${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}/ui.xml}"
  [[ -f "$xml" ]] || return 1

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
      return (c.get("text","") or "").strip(), c
  return "", None

def np_btn_xy(np, idx):
  kids = [c for c in list(np) if c.tag=="node"]
  if len(kids) <= idx: return None
  b = parse_bounds(kids[idx].get("bounds",""))
  return center(b) if b else None

# Hour NP (0): idx0=decrement (prev), idx2=increment (next)
h_cur, _ = np_value(nps[0])
h_dec = np_btn_xy(nps[0], 0)
h_inc = np_btn_xy(nps[0], 2)

# Minute NP (1)
m_cur, _ = np_value(nps[1])
m_dec = np_btn_xy(nps[1], 0)
m_inc = np_btn_xy(nps[1], 2)

# AM/PM NP (2) optional
tp_mode = "24"
ap_cur = ""
ap_am = ap_pm = None
if len(nps) >= 3:
  ap_cur, _ = np_value(nps[2])
  ap_cur = (ap_cur or "").strip().upper()
  # find tap centers for AM and PM by text
  for c in nps[2].iter("node"):
    t = ((c.get("text","") or "")).strip().upper()
    b = parse_bounds(c.get("bounds",""))
    if not b: continue
    if t == "AM": ap_am = center(b)
    if t == "PM": ap_pm = center(b)
  if ap_cur in ("AM","PM") or ap_am or ap_pm:
    tp_mode = "12"

print(f"TP_MODE={tp_mode}")
print(f"H_CUR={h_cur or 0}")
print(f"M_CUR={m_cur or 0}")
print(f"AP_CUR='{ap_cur}'")

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
  th=$((10#$th)); tm=$((10#$tm))

  local out
  out="$(ui_datetime_time_parse_vars)" || { warn "TimePicker not found"; return 1; }
  eval "$out"

  # defaults anti set -u
  : "${TP_MODE:=24}" "${H_CUR:=0}" "${M_CUR:=0}" "${AP_CUR:=}"
  : "${H_INC_X:=0}" "${H_INC_Y:=0}" "${H_DEC_X:=0}" "${H_DEC_Y:=0}"
  : "${M_INC_X:=0}" "${M_INC_Y:=0}" "${M_DEC_X:=0}" "${M_DEC_Y:=0}"
  : "${AP_AM_X:=0}" "${AP_AM_Y:=0}" "${AP_PM_X:=0}" "${AP_PM_Y:=0}"

  # sanity: coords must exist
  [[ "$H_INC_X" -ne 0 && "$H_DEC_X" -ne 0 && "$M_INC_X" -ne 0 && "$M_DEC_X" -ne 0 ]] \
    || { warn "TimePicker controls missing (coords=0)"; return 1; }

  local i

  if [[ "$TP_MODE" == "12" ]]; then
    # 24h -> (h12, ampm)
    local target_ampm="AM"
    (( th >= 12 )) && target_ampm="PM"
    local th12=$(( th % 12 )); (( th12 == 0 )) && th12=12

    # Hours wrap 12
    local curH=$((10#$H_CUR))
    local tgtH=$((10#$th12))
    local cur0=$((curH % 12))
    local tgt0=$((tgtH % 12))
    local fwd=$(((tgt0 - cur0 + 12) % 12))
    local bwd=$(((cur0 - tgt0 + 12) % 12))

    if (( fwd <= bwd )); then
      for ((i=0;i<fwd;i++)); do _ui_tap_xy "$H_INC_X" "$H_INC_Y"; done
    else
      for ((i=0;i<bwd;i++)); do _ui_tap_xy "$H_DEC_X" "$H_DEC_Y"; done
    fi

    # Minutes wrap 60
    local curM=$((10#$M_CUR))
    local tgtM=$tm
    fwd=$(((tgtM - curM + 60) % 60))
    bwd=$(((curM - tgtM + 60) % 60))

    if (( fwd <= bwd )); then
      for ((i=0;i<fwd;i++)); do _ui_tap_xy "$M_INC_X" "$M_INC_Y"; done
    else
      for ((i=0;i<bwd;i++)); do _ui_tap_xy "$M_DEC_X" "$M_DEC_Y"; done
    fi

    # AM/PM enforce (tap direct)
    local ap="${AP_CUR//\'/}"
    ap="${ap^^}"
    if [[ -n "$target_ampm" && "$ap" != "$target_ampm" ]]; then
      if [[ "$target_ampm" == "AM" && "$AP_AM_X" -ne 0 ]]; then _ui_tap_xy "$AP_AM_X" "$AP_AM_Y"; fi
      if [[ "$target_ampm" == "PM" && "$AP_PM_X" -ne 0 ]]; then _ui_tap_xy "$AP_PM_X" "$AP_PM_Y"; fi
    fi

  else
    # 24h mode
    local curH=$((10#$H_CUR))
    local tgtH=$th
    local fwd=$(((tgtH - curH + 24) % 24))
    local bwd=$(((curH - tgtH + 24) % 24))

    if (( fwd <= bwd )); then
      for ((i=0;i<fwd;i++)); do _ui_tap_xy "$H_INC_X" "$H_INC_Y"; done
    else
      for ((i=0;i<bwd;i++)); do _ui_tap_xy "$H_DEC_X" "$H_DEC_Y"; done
    fi

    local curM=$((10#$M_CUR))
    local tgtM=$tm
    fwd=$(((tgtM - curM + 60) % 60))
    bwd=$(((curM - tgtM + 60) % 60))

    if (( fwd <= bwd )); then
      for ((i=0;i<fwd;i++)); do _ui_tap_xy "$M_INC_X" "$M_INC_Y"; done
    else
      for ((i=0;i<bwd;i++)); do _ui_tap_xy "$M_DEC_X" "$M_DEC_Y"; done
    fi
  fi
}


ui_datetime_set_date_ymd() {
  local ymd="$1"  # YYYY-MM-DD

  # Assure-toi d'avoir un dump frais
  #ui_refresh

  # Base = date affichée dans l'UI (fallback: date système)
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
      ui_tap_any "one day later"  "resid::id/button_later"  "desc:One day later"  || true
    done
  elif (( diff < 0 )); then
    diff=$(( -diff ))
    local i
    for ((i=0;i<diff;i++)); do
      ui_tap_any "one day earlier" "resid::id/button_earlier" "desc:One day earlier" || true
    done
  fi

  #ui_refresh
}

ui_datetime_read_base_ymd() {
  local xml="${UI_XML:-${CFL_TMP_DIR:-$HOME/.cache/cfl_watch}/ui.xml}"
  [[ -f "$xml" ]] || return 1

  python - <<'PY' "$xml"
import re, sys
from datetime import datetime

xml_path = sys.argv[1]
s = open(xml_path, "r", encoding="utf-8", errors="ignore").read()

# Normalise les espaces non standards
s = s.replace("\u00A0", " ").replace("\u202F", " ")

# 1) Cible prioritaire: content-desc contenant "Search date:"
m = re.search(r'content-desc="[^"]*Search date:[^"]*"', s)
candidates = []
if m:
  candidates.append(m.group(0))

# 2) Fallback: n'importe quelle zone (ça sauve des vies)
candidates.append(s)

date_pat = re.compile(r'\b(\d{2})[./-](\d{2})[./-](\d{4})\b')

for blob in candidates:
  m2 = date_pat.search(blob)
  if not m2:
    continue
  dd, mm, yyyy = m2.group(1), m2.group(2), m2.group(3)

  # Luxembourg: day-first. (Si ton app se met en US un jour, on pleure après.)
  try:
    d = datetime.strptime(f"{dd}.{mm}.{yyyy}", "%d.%m.%Y").date()
    print(d.isoformat())  # YYYY-MM-DD
    sys.exit(0)
  except Exception:
    pass

sys.exit(1)
PY
}

ui_datetime_ok() {
  ui_tap_any "OK button" "resid:android:id/button1" || return 1
  ui_refresh
}
