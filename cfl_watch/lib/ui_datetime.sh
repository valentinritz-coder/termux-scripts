#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Requires: log/warn/maybe (common.sh), ui_refresh/ui_wait_resid/ui_tap_any (ui_* libs)
# Uses python to parse latest UI XML from $SNAP_DIR.

_ui_latest_xml() {
  ls -1t "$SNAP_DIR"/*.xml 2>/dev/null | head -n1 || true
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

  # OK button in Android dialog
  ui_wait_resid "OK button visible" "android:id/button1" "$t"
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

ui_datetime_set_time_24h() {
  local hm="$1"
  local hh="${hm%:*}"
  local mm="${hm#*:}"
  hh="${hh#0}"; mm="${mm#0}"

  ui_refresh
  _ui_eval_vars

  # Convert to 12h + AM/PM
  read -r h12 ap <<< "$(_ui_to_12h "$hh")"
  local m2
  m2="$(printf "%02d" "$mm")"

  # Hours (1..12)
  if [[ -n "${H_CUR:-}" ]]; then
    _ui_np_step_to "hour" "$H_CUR" "$h12" 1 12 "${H_UP_X:-0}" "${H_UP_Y:-0}" "${H_DOWN_X:-0}" "${H_DOWN_Y:-0}"
  else
    warn "Hour picker not parsed"
  fi

  ui_refresh
  _ui_eval_vars

  # Minutes (0..59) – xml gives "48" but we accept 00..59
  if [[ -n "${M_CUR:-}" ]]; then
    # current may be "08" or "8"
    local curm="${M_CUR#0}"
    local tgtm="${m2#0}"
    _ui_np_step_to "minute" "${curm:-0}" "${tgtm:-0}" 0 59 "${M_UP_X:-0}" "${M_UP_Y:-0}" "${M_DOWN_X:-0}" "${M_DOWN_Y:-0}"
  else
    warn "Minute picker not parsed"
  fi

  ui_refresh
  _ui_eval_vars

  # AM/PM
  if [[ -n "${AP_CUR:-}" ]]; then
    if [[ "${AP_CUR^^}" != "${ap^^}" ]]; then
      # If the "other" value is on the up button, tap it
      if [[ -n "${AP_OTHER:-}" && "${AP_OTHER^^}" == "${ap^^}" && -n "${AP_UP_X:-}" ]]; then
        _ui_tap_xy "$AP_UP_X" "$AP_UP_Y"
      else
        # fallback: tap inside the AM/PM input
        _ui_tap_xy "${AP_INP_X:-${AP_UP_X:-0}}" "${AP_INP_Y:-${AP_UP_Y:-0}}"
      fi
    fi
  fi

  ui_refresh
}

ui_datetime_set_date_ymd() {
  local ymd="$1"  # YYYY-MM-DD

  # Force baseline = today (best effort)
  ui_tap_any "preset now" \
    "resid::id/button_datetime_forward_1" \
    "text:Now" \
  || true
  ui_refresh

  # Compute diff from device date (today) to target
  local diff
  diff="$(python - <<'PY' "$(date +%Y-%m-%d)" "$ymd"
import sys, datetime
a = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d").date()
b = datetime.datetime.strptime(sys.argv[2], "%Y-%m-%d").date()
print((b-a).days)
PY
)"
  diff="${diff:-0}"

  # Tap earlier/later
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

  ui_refresh
}

ui_datetime_ok() {
  ui_tap_any "OK button" "resid:android:id/button1" || return 1
  ui_refresh
}
