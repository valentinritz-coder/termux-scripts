cat > /sdcard/cfl_watch/map.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PKG="de.hafas.android.cfl"
OUT_BASE="/sdcard/cfl_watch/map"
DEPTH=1
MAX_SCREENS=25
MAX_ACTIONS=8
DELAY=1.5
LAUNCH=0   # map_run.sh launches the app

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg) PKG="$2"; shift 2 ;;
    --out) OUT_BASE="$2"; shift 2 ;;
    --depth) DEPTH="$2"; shift 2 ;;
    --max-screens) MAX_SCREENS="$2"; shift 2 ;;
    --max-actions) MAX_ACTIONS="$2"; shift 2 ;;
    --delay) DELAY="$2"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    *) shift ;;
  esac
done

run_root() {
  if command -v su >/dev/null 2>&1; then
    su -c "PATH=/system/bin:/system/xbin:/vendor/bin:\$PATH; $1"
  else
    sh -c "$1"
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[!] Missing: $1"; exit 2; }; }
need_cmd python

now_ts() { date +"%Y-%m-%d_%H-%M-%S"; }

MAP_DIR="$OUT_BASE/$(now_ts)"
mkdir -p "$MAP_DIR"/{screens,tmp}
VISITED="$MAP_DIR/visited.txt"
COUNT_FILE="$MAP_DIR/count.txt"
echo 0 > "$COUNT_FILE"
: > "$VISITED"

echo "[*] map_dir=$MAP_DIR"
echo "[*] pkg=$PKG depth=$DEPTH max_screens=$MAX_SCREENS max_actions=$MAX_ACTIONS delay=$DELAY"

capture_screen() {
  local out_xml="$1"
  local out_png="$2"
  run_root "uiautomator dump --compressed '$out_xml'" >/dev/null 2>&1 || return 1
  run_root "screencap -p '$out_png'" >/dev/null 2>&1 || return 1
  return 0
}

raw_xml_hash() {
  local xml="$1"
  python - "$xml" <<'PY'
import sys, hashlib
p=sys.argv[1]
print(hashlib.sha1(open(p,'rb').read()).hexdigest())
PY
}

hash_screen_norm() {
  local xml="$1"
  python - "$xml" <<'PY'
import sys, re, hashlib, xml.etree.ElementTree as ET
xml_path=sys.argv[1]
root=ET.parse(xml_path).getroot()

def clean(s):
  s=(s or "").strip()
  s=re.sub(r"\s+"," ",s)
  return s

def norm(s):
  s=re.sub(r"\b([01]?\d|2[0-3])[:h][0-5]\d\b","<TIME>",s)
  s=re.sub(r"\b\d+\b","<NUM>",s)
  return s

parts=[]
for n in root.iter("node"):
  rid=clean(n.attrib.get("resource-id"))
  cls=clean(n.attrib.get("class"))
  clk=clean(n.attrib.get("clickable"))
  txt=norm(clean(n.attrib.get("text")))
  des=norm(clean(n.attrib.get("content-desc")))
  pkg=clean(n.attrib.get("package"))
  if not (txt or des or rid): 
    continue
  parts.append(f"{pkg}|{rid}|{cls}|{clk}|T={txt}|D={des}")

data="\n".join(sorted(set(parts))).encode("utf-8","replace")
print(hashlib.sha1(data).hexdigest())
PY
}

list_actions() {
  local xml="$1"
  local max_actions="$2"
  python - "$xml" "$max_actions" <<'PY'
import sys, re, xml.etree.ElementTree as ET
xml_path=sys.argv[1]
max_actions=int(sys.argv[2])
root=ET.parse(xml_path).getroot()

def clean(s):
  s=(s or "").strip()
  s=re.sub(r"\s+"," ",s)
  return s

def center(bounds):
  m=re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds or "")
  if not m: return None
  x1,y1,x2,y2=map(int,m.groups())
  cx=(x1+x2)//2
  cy=(y1+y2)//2
  area=max(0,(x2-x1))*max(0,(y2-y1))
  return cx,cy,area

bad=re.compile(r"\b(pay|payer|achat|acheter|purchase|buy|confirm|confirmer|delete|supprimer|remove|retirer|logout|déconnexion|sign out|envoyer|send)\b", re.I)

cands=[]
for n in root.iter("node"):
  if n.attrib.get("clickable")!="true": 
    continue
  if n.attrib.get("enabled")!="true":
    continue
  c=center(n.attrib.get("bounds"))
  if not c: 
    continue
  x,y,area=c
  if area<18000 or y<120: 
    continue

  txt=clean(n.attrib.get("text"))
  des=clean(n.attrib.get("content-desc"))
  rid=clean(n.attrib.get("resource-id"))
  cls=clean(n.attrib.get("class"))

  label=" | ".join([p for p in [rid,cls,txt,des] if p])
  if not label or bad.search(label):
    continue

  score=0
  if rid: score+=10
  if txt or des: score+=4
  score+=min(10, area//80000)

  cands.append((score,-area,x,y,label[:140]))

cands.sort(reverse=True)

out=[]
seen=set()
for score,neg_area,x,y,label in cands:
  key=(x//10,y//10)
  if key in seen: 
    continue
  seen.add(key)
  out.append((x,y,label))
  if len(out)>=max_actions: 
    break

for x,y,label in out:
  print(f"{x}\t{y}\t{label}")
PY
}

explore() {
  local depth="$1"

  local count
  count=$(cat "$COUNT_FILE")
  if [ "$count" -ge "$MAX_SCREENS" ]; then return 0; fi

  local tmp_xml="$MAP_DIR/tmp/current.xml"
  local tmp_png="$MAP_DIR/tmp/current.png"
  capture_screen "$tmp_xml" "$tmp_png" || return 0

  local h
  h="$(hash_screen_norm "$tmp_xml")"
  grep -qx "$h" "$VISITED" && return 0

  echo "$h" >> "$VISITED"
  count=$((count+1)); echo "$count" > "$COUNT_FILE"

  local scr_dir="$MAP_DIR/screens/$h"
  mkdir -p "$scr_dir"
  cp -f "$tmp_xml" "$scr_dir/ui.xml"
  cp -f "$tmp_png" "$scr_dir/screen.png"
  echo "[+] screen#$count hash=$h depth=$depth"

  [ "$depth" -le 0 ] && return 0

  local actions_file="$scr_dir/actions.txt"
  list_actions "$scr_dir/ui.xml" "$MAX_ACTIONS" > "$actions_file" || true

  local base_raw
  base_raw="$(raw_xml_hash "$scr_dir/ui.xml")" || base_raw=""

  local i=0
  while IFS=$'\t' read -r x y label; do
    [ -z "${x:-}" ] && continue
    i=$((i+1))
    echo "    -> tap#$i ($x,$y) $label"

    run_root "input tap $x $y" >/dev/null 2>&1 || true
    sleep "$DELAY"

    local after_xml="$MAP_DIR/tmp/after.xml"
    local after_png="$MAP_DIR/tmp/after.png"
    capture_screen "$after_xml" "$after_png" || continue

    local after_raw
    after_raw="$(raw_xml_hash "$after_xml")" || after_raw=""

    if [ -n "$base_raw" ] && [ "$after_raw" = "$base_raw" ]; then
      echo "       (no screen change -> no BACK)"
      continue
    fi

    explore $((depth-1))

    run_root "input keyevent 4" >/dev/null 2>&1 || true
    sleep 0.8

    capture_screen "$after_xml" "$after_png" || true
    base_raw="$(raw_xml_hash "$after_xml" 2>/dev/null || true)"

    local c; c=$(cat "$COUNT_FILE")
    [ "$c" -ge "$MAX_SCREENS" ] && break
  done < "$actions_file"
}

explore "$DEPTH"
echo "[*] Done. Visited screens: $(wc -l < "$VISITED" | tr -d ' ')"
echo "[*] Output: $MAP_DIR"
SH

chmod +x /sdcard/cfl_watch/map.sh
