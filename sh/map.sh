cat > /sdcard/cfl_watch/map.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PKG="de.hafas.android.cfl"
OUT_BASE="/sdcard/cfl_watch/map"
DEPTH=1
MAX_SCREENS=25
MAX_ACTIONS=8
DELAY=1.5
LAUNCH=1

SER="${ANDROID_SERIAL:-127.0.0.1:37099}"

usage() {
  cat <<EOF
Usage: bash /sdcard/cfl_watch/map.sh [options]
  --pkg de.hafas.android.cfl
  --out /sdcard/cfl_watch/map
  --depth 1
  --max-screens 25
  --max-actions 8
  --delay 1.5
  --no-launch
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

need() { command -v "$1" >/dev/null 2>&1 || { echo "[!] missing: $1"; exit 1; }; }
need python
need adb

run_root() { su -c "PATH=/system/bin:/system/xbin:/vendor/bin:\$PATH; $1"; }
inject()   { adb -s "$SER" shell "$@"; }

now_ts() { date +"%Y-%m-%d_%H-%M-%S"; }

MAP_DIR="$OUT_BASE/$(now_ts)"
mkdir -p "$MAP_DIR"/{screens,tmp}
VISITED="$MAP_DIR/visited.txt"
COUNT_FILE="$MAP_DIR/count.txt"
echo 0 > "$COUNT_FILE"
: > "$VISITED"

echo "[*] map_dir=$MAP_DIR"
echo "[*] device=$SER pkg=$PKG depth=$DEPTH max_screens=$MAX_SCREENS max_actions=$MAX_ACTIONS delay=$DELAY launch=$LAUNCH"

if [ "$LAUNCH" -eq 1 ]; then
  inject monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 1.5
fi

capture_screen() {
  local out_xml="$1"
  local out_png="$2"
  run_root "uiautomator dump --compressed '$out_xml'" >/dev/null 2>&1 || return 1
  run_root "screencap -p '$out_png'" >/dev/null 2>&1 || return 1
  return 0
}

hash_xml_norm() {
  python - "$1" <<'PY'
import sys,re,hashlib,xml.etree.ElementTree as ET
p=sys.argv[1]
root=ET.parse(p).getroot()
def clean(s): return re.sub(r"\s+"," ",(s or "").strip())
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
  if not (rid or txt or des): 
    continue
  parts.append(f"{pkg}|{rid}|{cls}|{clk}|T={txt}|D={des}")
data="\n".join(sorted(set(parts))).encode()
print(hashlib.sha1(data).hexdigest())
PY
}

hash_file() {
  python - "$1" <<'PY'
import sys,hashlib
p=sys.argv[1]
h=hashlib.sha1()
with open(p,'rb') as f:
  for b in iter(lambda: f.read(1024*1024), b''):
    h.update(b)
print(h.hexdigest())
PY
}

list_actions() {
  python - "$1" "$2" <<'PY'
import sys,re,xml.etree.ElementTree as ET
xml_path=sys.argv[1]; max_actions=int(sys.argv[2])
root=ET.parse(xml_path).getroot()

def clean(s): return re.sub(r"\s+"," ",(s or "").strip())
def center(bounds):
  m=re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds or "")
  if not m: return None
  x1,y1,x2,y2=map(int,m.groups())
  cx=(x1+x2)//2; cy=(y1+y2)//2
  area=max(0,x2-x1)*max(0,y2-y1)
  return cx,cy,area

bad=re.compile(r"\b(pay|payer|achat|acheter|purchase|buy|confirm|confirmer|delete|supprimer|remove|retirer|logout|déconnexion|sign out)\b",re.I)
cands=[]
for n in root.iter("node"):
  if n.attrib.get("clickable")!="true" or n.attrib.get("enabled")!="true": 
    continue
  c=center(n.attrib.get("bounds"))
  if not c: 
    continue
  x,y,area=c
  if area<18000 or y<120:
    continue
  rid=clean(n.attrib.get("resource-id"))
  cls=clean(n.attrib.get("class"))
  txt=clean(n.attrib.get("text"))
  des=clean(n.attrib.get("content-desc"))
  label=" | ".join([p for p in [rid,cls,txt,des] if p])[:140]
  if not label or bad.search(label): 
    continue
  score=(5 if rid else 0)+(2 if (txt or des) else 0)+min(10,area//80000)
  cands.append((score,area,x,y,label))

cands.sort(key=lambda t:(t[0],t[1]), reverse=True)
out=[]; seen=set()
for score,area,x,y,label in cands:
  k=(x//10,y//10)
  if k in seen: 
    continue
  seen.add(k)
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
  count="$(cat "$COUNT_FILE")"
  [ "$count" -ge "$MAX_SCREENS" ] && return 0

  local tmp_xml="$MAP_DIR/tmp/current.xml"
  local tmp_png="$MAP_DIR/tmp/current.png"
  capture_screen "$tmp_xml" "$tmp_png" || return 0

  local hx hp h
  hx="$(hash_xml_norm "$tmp_xml")"
  hp="$(hash_file "$tmp_png")"
  h="${hx}_${hp}"

  if grep -qx "$h" "$VISITED"; then
    return 0
  fi

  echo "$h" >> "$VISITED"
  count=$((count+1))
  echo "$count" > "$COUNT_FILE"

  local scr_dir="$MAP_DIR/screens/$count"
  mkdir -p "$scr_dir"
  cp -f "$tmp_xml" "$scr_dir/ui.xml"
  cp -f "$tmp_png" "$scr_dir/screen.png"
  echo "[+] screen#$count depth=$depth hash=$h"

  [ "$depth" -le 0 ] && return 0

  local actions_file="$scr_dir/actions.txt"
  list_actions "$scr_dir/ui.xml" "$MAX_ACTIONS" > "$actions_file" || true

  local i=0
  while IFS=$'\t' read -r x y label; do
    [ -z "${x:-}" ] && continue
    i=$((i+1))
    echo "    -> tap#$i ($x,$y) $label"
    inject input tap "$x" "$y" >/dev/null 2>&1 || true
    sleep "$DELAY"

    explore $((depth-1))

    inject input keyevent 4 >/dev/null 2>&1 || true
    sleep 0.8

    local c
    c="$(cat "$COUNT_FILE")"
    [ "$c" -ge "$MAX_SCREENS" ] && break
  done < "$actions_file"
}

explore "$DEPTH"
echo "[*] Done. Visited screens: $(wc -l < "$VISITED" | tr -d ' ')"
echo "[*] Output: $MAP_DIR"
SH

chmod +x /sdcard/cfl_watch/map.sh
sed -i 's/\r$//' /sdcard/cfl_watch/map.sh 2>/dev/null || true
