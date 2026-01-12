#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# UI selector helpers (parsing the uiautomator XML locally).
# Depends on: python, warn, log, maybe tap (from lib/common.sh).
#
# Provides:
#   node_center
#   first_result_center
#   tap_by_selector
#   tap_first_result

node_center(){
  local dump="$1"; shift
  python - "$dump" "$@" <<'PY' 2>/dev/null
import sys, re, xml.etree.ElementTree as ET

dump = sys.argv[1]
pairs = [a.split("=",1) for a in sys.argv[2:]]
criteria = [(k,v) for k,v in pairs]

_bounds = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")

def center(bounds):
    m = _bounds.match(bounds or "")
    if not m:
        return None
    x1,y1,x2,y2 = map(int, m.groups())
    if x2<=x1 or y2<=y1:
        return None
    return (x1+x2)//2, (y1+y2)//2

try:
    root = ET.parse(dump).getroot()
except Exception:
    sys.exit(0)

parent = {c:p for p in root.iter() for c in p}

def matches(node):
    for attr, expected in criteria:
        actual = node.get(attr,"") or ""
        if expected.lower() not in actual.lower():
            return False
    return True

for node in root.iter("node"):
    if not matches(node):
        continue
    cur = node
    while cur is not None and cur.get("clickable","") != "true":
        cur = parent.get(cur)
    target = cur if cur is not None else node
    c = center(target.get("bounds"))
    if c:
        print(f"{c[0]} {c[1]}")
        sys.exit(0)

sys.exit(0)
PY
}

tap_bounds() {
  # Usage:
  #   tap_bounds "label" "[x1,y1][x2,y2]"

  local label="$1"
  local bounds="$2"

  if [[ ! "$bounds" =~ \[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\] ]]; then
    warn "tap_bounds: invalid bounds ($bounds)"
    return 1
  fi

  local x1="${BASH_REMATCH[1]}"
  local y1="${BASH_REMATCH[2]}"
  local x2="${BASH_REMATCH[3]}"
  local y2="${BASH_REMATCH[4]}"

  # Centre du rectangle
  local x=$(( (x1 + x2) / 2 ))
  local y=$(( (y1 + y2) / 2 ))

  log "Tap $label at $x,$y"
  maybe tap "$x" "$y"
  return 0
}

first_result_center(){
  local dump="$1"
  python - "$dump" <<'PY' 2>/dev/null
import re, sys, xml.etree.ElementTree as ET

dump = sys.argv[1]
LIST_SUFFIX = ":id/list_location_results"
_bounds = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")

def parse(b):
    m = _bounds.match(b or "")
    if not m:
        return None
    x1,y1,x2,y2 = map(int, m.groups())
    if x2<=x1 or y2<=y1:
        return None
    return x1,y1,x2,y2

def ctr(bb):
    x1,y1,x2,y2 = bb
    return (x1+x2)//2, (y1+y2)//2

try:
    root = ET.parse(dump).getroot()
except Exception:
    sys.exit(0)

list_node = None
for n in root.iter("node"):
    rid = n.get("resource-id","")
    if rid.endswith(LIST_SUFFIX):
        list_node = n
        break

if list_node is None:
    sys.exit(0)

for child in list_node.iter("node"):
    if child is list_node:
        continue
    if child.get("clickable") == "true" and child.get("enabled") != "false":
        bb = parse(child.get("bounds"))
        if not bb:
            continue
        w = bb[2]-bb[0]; h = bb[3]-bb[1]
        if w*h < 20000:
            continue
        x,y = ctr(bb)
        print(f"{x} {y}")
        sys.exit(0)

sys.exit(0)
PY
}

tap_by_selector(){
  local label="$1"; shift
  local dump="$1"; shift
  local coords
  coords="$(node_center "$dump" "$@")"
  if [[ -z "${coords// }" ]]; then
    warn "Selector introuvable: $label (criteria: $*)"
    return 1
  fi
  local x y
  read -r x y <<<"$coords"
  log "Tap $label at $x,$y"
  maybe tap "$x" "$y"
  return 0
}

tap_first_result(){
  local label="$1"
  local dump="$2"
  local coords
  coords="$(first_result_center "$dump")"
  if [[ -z "${coords// }" ]]; then
    warn "Pas de $label"
    return 1
  fi
  local x y
  read -r x y <<<"$coords"
  log "Tap $label at $x,$y"
  maybe tap "$x" "$y"
  return 0
}
