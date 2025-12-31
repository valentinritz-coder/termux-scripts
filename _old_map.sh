cat > /sdcard/cfl_watch/map.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PKG="de.hafas.android.cfl"
OUT_BASE="/sdcard/cfl_watch/map"
DEPTH=2
MAX_SCREENS=80
MAX_ACTIONS=10
DELAY=1.2
LAUNCH=1

usage() {
  cat <<EOF
Usage:
  bash /sdcard/cfl_watch/map.sh [options]

Options:
  --pkg de.hafas.android.cfl
  --out /sdcard/cfl_watch/map
  --depth 2
  --max-screens 80
  --max-actions 10
  --delay 1.2
  --no-launch   (do not launch app; assumes CFL already foreground)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg) PKG="$2"; shift 2 ;;
    --out) OUT_BASE="$2"; shift 2 ;;
    --depth) DEPTH="$2"; shift 2 ;;
    --max-screens) MAX_SCREENS="$2"; shift 2 ;;
    --max-actions) MAX_ACTIONS="$2"; shift 2 ;;
    --delay) DELAY="$2"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) shift ;;
  esac
done

run_root() {
  if command -v su >/dev/null 2>&1; then su -c "$1"; else sh -c "$1"; fi
}

now_ts() { date +"%Y-%m-%d_%H-%M-%S"; }

MAP_DIR="$OUT_BASE/$(now_ts)"
mkdir -p "$MAP_DIR"/{screens,tmp}
VISITED="$MAP_DIR/visited.txt"
COUNT_FILE="$MAP_DIR/count.txt"
echo 0 > "$COUNT_FILE"
: > "$VISITED"

echo "[*] map_dir=$MAP_DIR"
echo "[*] pkg=$PKG depth=$DEPTH max_screens=$MAX_SCREENS max_actions=$MAX_ACTIONS delay=$DELAY launch=$LAUNCH"

# Optional: launch app
if [ "$LAUNCH" -eq 1 ]; then
  # monkey brings app to foreground without needing explicit activity name
  run_root "monkey -p '$PKG' -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1 || true
  sleep 1.2
fi

get_focus_pkg() {
  # best-effort parse focused package
  run_root "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp' -m 1" 2>/dev/null \
    | sed -n 's/.* \([a-zA-Z0-9_.]\+\)\/.*/\1/p' | head -n 1
}

capture_screen() {
  local out_xml="$1"
  local out_png="$2"
  run_root "uiautomator dump --compressed '$out_xml'" >/dev/null 2>&1 || return 1
  run_root "screencap -p '$out_png'" >/dev/null 2>&1 || return 1
  return 0
}

hash_screen() {
  local xml="$1"
  python - "$xml" <<'PY'
import sys, re, hashlib, xml.etree.ElementTree as ET
xml_path = sys.argv[1]
tree = ET.parse(xml_path)
root = tree.getroot()

# Build a stable signature using resource-id/class/clickable + normalized text/desc
def clean(s):
  s = (s or "").strip()
  s = re.sub(r"\s+", " ", s)
  return s

def norm(s):
  # mask noisy stuff (times/numbers) lightly for hashing
  s = re.sub(r"\b([01]?\d|2[0-3])[:h][0-5]\d\b", "<TIME>", s)
  s = re.sub(r"\b\d+\b", "<NUM>", s)
  return s

parts = []
for n in root.iter("node"):
  rid = clean(n.attrib.get("resource-id"))
  cls = clean(n.attrib.get("class"))
  clk = clean(n.attrib.get("clickable"))
  txt = norm(clean(n.attrib.get("text")))
  des = norm(clean(n.attrib.get("content-desc")))
  pkg = clean(n.attrib.get("package"))
  if not (txt or des or rid):
    continue
  parts.append(f"{pkg}|{rid}|{cls}|{clk}|T={txt}|D={des}")

data = "\n".join(sorted(set(parts))).encode("utf-8", "replace")
print(hashlib.sha1(data).hexdigest())
PY
}

list_actions() {
  local xml="$1"
  local max_actions="$2"
  python - "$xml" "$max_actions" <<'PY'
import sys, re, xml.etree.ElementTree as ET

xml_path = sys.argv[1]
max_actions = int(sys.argv[2])

tree = ET.parse(xml_path)
root = tree.getroot()

def clean(s):
  s = (s or "").strip()
  s = re.sub(r"\s+", " ", s)
  return s

def center(bounds):
  # bounds like: [0,525][1080,862]
  m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
  if not m: return None
  x1,y1,x2,y2 = map(int, m.groups())
  cx = (x1+x2)//2
  cy = (y1+y2)//2
  area = max(0, (x2-x1)) * max(0, (y2-y1))
  return cx, cy, area, (x1,y1,x2,y2)

# Very conservative blacklist to avoid destructive actions
bad = re.compile(r"\b(pay|payer|achat|acheter|purchase|buy|confirm|confirmer|delete|supprimer|remove|retirer|logout|déconnexion|sign out|envoyer|send)\b", re.I)

cands = []
for n in root.iter("node"):
  if n.attrib.get("clickable") != "true":
    continue
  if n.attrib.get("enabled") != "true":
    continue
  b = n.attrib.get("bounds")
  if not b:
    continue
  c = center(b)
  if not c:
    continue
  x,y,area,(x1,y1,x2,y2) = c

  # Skip tiny tap targets
  if area < 18_000:
    continue

  txt = clean(n.attrib.get("text"))
  des = clean(n.attrib.get("content-desc"))
  rid = clean(n.attrib.get("resource-id"))
  cls = clean(n.attrib.get("class"))

  label = " | ".join([p for p in [rid, cls, txt, des] if p])
  if not label:
    continue
  if bad.search(label):
    continue

  # Avoid tapping the system/status bar-ish region
  if y < 120:
    continue

  # Score: prefer resource-id and bigger targets
  score = 0
  if rid: score += 5
  if txt or des: score += 2
  score += min(10, area // 80_000)

  cands.append((score, -area, x, y, label[:120]))

cands.sort(reverse=True)
out = []
seen_xy = set()
for score, neg_area, x, y, label in cands:
  key = (x//10, y//10)  # de-dup close coords
  if key in seen_xy:
    continue
  seen_xy.add(key)
  out.append((x, y, label))
  if len(out) >= max_actions:
    break

for x,y,label in out:
  print(f"{x}\t{y}\t{label}")
PY
}

explore() {
  local depth="$1"

  # Stop if too many screens
  local count
  count=$(cat "$COUNT_FILE")
  if [ "$count" -ge "$MAX_SCREENS" ]; then
    return 0
  fi

  local focus
  focus="$(get_focus_pkg || true)"
  if [ -n "$focus" ] && [ "$focus" != "$PKG" ]; then
    # Not in target app, go back
    run_root "input keyevent 4" >/dev/null 2>&1 || true
    sleep 0.6
    return 0
  fi

  local tmp_xml="$MAP_DIR/tmp/current.xml"
  local tmp_png="$MAP_DIR/tmp/current.png"
  if ! capture_screen "$tmp_xml" "$tmp_png"; then
    return 0
  fi

  local h
  h="$(hash_screen "$tmp_xml")"

  if grep -qx "$h" "$VISITED"; then
    return 0
  fi

  # Mark visited
  echo "$h" >> "$VISITED"
  count=$((count+1))
  echo "$count" > "$COUNT_FILE"

  # Persist artifacts
  local scr_dir="$MAP_DIR/screens/$h"
  mkdir -p "$scr_dir"
  cp -f "$tmp_xml" "$scr_dir/ui.xml"
  cp -f "$tmp_png" "$scr_dir/screen.png"
  {
    echo "hash=$h"
    echo "count=$count"
    echo "depth=$depth"
    echo "focus_pkg=$(get_focus_pkg || true)"
    echo
    run_root "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp' -m 2" 2>/dev/null || true
  } > "$scr_dir/meta.txt" || true

  echo "[+] screen#$count hash=$h depth=$depth"

  if [ "$depth" -le 0 ]; then
    return 0
  fi

  # Enumerate actions
  local actions_file="$scr_dir/actions.txt"
  list_actions "$scr_dir/ui.xml" "$MAX_ACTIONS" > "$actions_file" || true

  local i=0
  while IFS=$'\t' read -r x y label; do
    [ -z "${x:-}" ] && continue
    i=$((i+1))
    echo "    -> tap#$i ($x,$y) $label"
    run_root "input tap $x $y" >/dev/null 2>&1 || true
    sleep "$DELAY"

    explore $((depth-1))

    # Back to previous
    run_root "input keyevent 4" >/dev/null 2>&1 || true
    sleep 0.8

    # Stop if too many screens
    local c
    c=$(cat "$COUNT_FILE")
    if [ "$c" -ge "$MAX_SCREENS" ]; then
      break
    fi
  done < "$actions_file"
}

explore "$DEPTH"

echo
echo "[*] Done. Visited screens: $(wc -l < "$VISITED" | tr -d ' ')"
echo "[*] Output: $MAP_DIR"
SH

chmod +x /sdcard/cfl_watch/map.sh 2>/dev/null || true
