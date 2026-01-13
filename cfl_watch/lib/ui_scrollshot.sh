#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Scrollshot "region-based" (CFL WATCH)
#
# Capture une page scrollable en plusieurs screenshots puis stitch en une seule image,
# mais en CROPPANT le haut pour ne garder que la zone à partir d’un élément (resid).
#
# Dépendances attendues (déjà chez toi):
# - log warn maybe sleep_s
# - ui_refresh + UI_DUMP_CACHE
# - resid_regex / regex_escape_ere (pas obligatoire ici)
# - ui_scroll_down (pas utilisé: on swipe dans la zone)
#
# Dépendances externes:
# - adb
# - python + pillow (pip install pillow)

: "${SCROLLSHOT_BOTTOM_CROP:=160}"   # retire navbar / bas écran
: "${SCROLLSHOT_MIN_OV:=120}"
: "${SCROLLSHOT_MAX_OV:=900}"
: "${SCROLLSHOT_OV_STEP:=10}"
: "${SCROLLSHOT_MAX_SCROLL:=25}"
: "${SCROLLSHOT_SETTLE:=0.45}"
: "${SCROLLSHOT_STOP_STREAK:=1}"    # stop après 1 doublon
: "${SCROLLSHOT_SWIPE_MS:=300}"

# fallback safe_tag si pas sourcé
if ! command -v safe_tag >/dev/null 2>&1; then
  safe_tag(){ printf '%s' "$1" | tr ' /' '__' | tr -cd 'A-Za-z0-9._-'; }
fi

_ui_serial() {
  printf '%s' "${SERIAL:-${ANDROID_SERIAL:-127.0.0.1:37099}}"
}

ui_screencap_png() {
  local out="$1"
  local serial; serial="$(_ui_serial)"
  adb -s "$serial" exec-out screencap -p > "$out" \
    || { warn "ui_screencap_png failed: $out"; return 1; }
}

_ui_png_size() {
  # prints: "W H"
  python - "$1" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1])
print(im.size[0], im.size[1])
PY
}

ui_get_resid_bounds_topmost() {
  # Usage: ui_get_resid_bounds_topmost ":id/journey_details_head"
  # Output: "x1 y1 x2 y2" (topmost match by y1)
  local resid="$1"
  [[ -n "${UI_DUMP_CACHE:-}" && -s "${UI_DUMP_CACHE:-}" ]] || ui_refresh

  # Normaliser :id/foo -> package:id/foo
  if [[ "$resid" == :id/* ]]; then
    resid="${APP_PACKAGE:-de.hafas.android.cfl}${resid}"
  fi

  python - "$UI_DUMP_CACHE" "$resid" <<'PY'
import sys, re, xml.etree.ElementTree as ET

dump, resid = sys.argv[1], sys.argv[2]
root = ET.parse(dump).getroot()
rb = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")

best = None  # (y1, x1,y1,x2,y2)

for n in root.iter("node"):
    if n.get("resource-id") != resid:
        continue
    b = n.get("bounds") or ""
    m = rb.match(b)
    if not m:
        continue
    x1,y1,x2,y2 = map(int, m.groups())
    if best is None or y1 < best[0]:
        best = (y1, x1,y1,x2,y2)

if best is None:
    sys.exit(1)

_, x1,y1,x2,y2 = best
print(x1, y1, x2, y2)
PY
}

_ui_hash_png_center() {
  # Hash robuste: centre de l'image CROPPÉE (évite status bar/spinners).
  python - "$1" 2>/dev/null <<'PY' || sha1sum "$1" | awk '{print $1}'
import sys, hashlib
from PIL import Image

p = sys.argv[1]
im = Image.open(p).convert("RGB")
w,h = im.size

x1 = int(w*0.08); x2 = int(w*0.92)
y1 = int(h*0.20); y2 = int(h*0.85)
crop = im.crop((x1,y1,x2,y2))

print(hashlib.sha1(crop.tobytes()).hexdigest())
PY
}

_ui_swipe() {
  local x="$1" y1="$2" y2="$3" ms="${4:-$SCROLLSHOT_SWIPE_MS}"
  local serial; serial="$(_ui_serial)"
  maybe adb -s "$serial" shell input swipe "$x" "$y1" "$x" "$y2" "$ms"
}

ui_scrollshot_stitch() {
  # Usage: ui_scrollshot_stitch DIR OUT.png
  local dir="$1"
  local out="$2"

  python - "$dir" "$out" <<'PY'
import os, sys
from PIL import Image, ImageChops

dirp = sys.argv[1]
outp = sys.argv[2]

TOP_CROP    = int(os.environ.get("SCROLLSHOT_TOP_CROP", "0"))
BOTTOM_CROP = int(os.environ.get("SCROLLSHOT_BOTTOM_CROP", "160"))

MIN_OV  = int(os.environ.get("SCROLLSHOT_MIN_OV", "120"))
MAX_OV  = int(os.environ.get("SCROLLSHOT_MAX_OV", "900"))
OV_STEP = int(os.environ.get("SCROLLSHOT_OV_STEP", "10"))

files = sorted([f for f in os.listdir(dirp) if f.lower().endswith(".png")])
if not files:
    raise SystemExit("No PNGs found")

def load_crop(fp):
    im = Image.open(fp).convert("RGB")
    w,h = im.size
    top = min(TOP_CROP, h-1)
    bot = min(BOTTOM_CROP, h-1-top)
    return im.crop((0, top, w, h-bot))

imgs = [load_crop(os.path.join(dirp, f)) for f in files]

def score(a, b, ov):
    ov = min(ov, a.size[1], b.size[1])
    w = min(a.size[0], b.size[0])

    a_strip = a.crop((0, a.size[1]-ov, w, a.size[1]))
    b_strip = b.crop((0, 0, w, ov))

    # downscale largeur pour perf
    target_w = 540
    if w > target_w:
        scale = target_w / w
        a_strip = a_strip.resize((target_w, max(1, int(ov*scale))))
        b_strip = b_strip.resize((target_w, max(1, int(ov*scale))))

    diff = ImageChops.difference(a_strip, b_strip)
    hist = diff.histogram()
    return sum(i*v for i,v in enumerate(hist))

base = imgs[0]
for nxt in imgs[1:]:
    max_ov = min(MAX_OV, base.size[1], nxt.size[1])
    best_ov = MIN_OV
    best_sc = None

    for ov in range(MIN_OV, max_ov+1, OV_STEP):
        sc = score(base, nxt, ov)
        if best_sc is None or sc < best_sc:
            best_sc = sc
            best_ov = ov

    w = max(base.size[0], nxt.size[0])
    new_h = base.size[1] + (nxt.size[1] - best_ov)
    canvas = Image.new("RGB", (w, new_h))
    canvas.paste(base, (0, 0))
    canvas.paste(nxt.crop((0, best_ov, nxt.size[0], nxt.size[1])), (0, base.size[1]))
    base = canvas

os.makedirs(os.path.dirname(outp), exist_ok=True)
base.save(outp, "PNG")
print(outp)
PY
}

ui_scrollshot_region() {
  # Scrollshot "à partir de" un resid.
  #
  # Usage:
  #   fullpng="$(ui_scrollshot_region "tag" ":id/journey_details_head" [max_scroll] [settle] [pad_up] [bottom_crop])"
  #
  local tag="$1"
  local anchor_resid="$2"
  local max_scroll="${3:-$SCROLLSHOT_MAX_SCROLL}"
  local settle="${4:-$SCROLLSHOT_SETTLE}"
  local pad_up="${5:-0}"                   # pixels au-dessus de l'anchor à inclure
  local bottom_crop="${6:-$SCROLLSHOT_BOTTOM_CROP}"

  [[ -n "${SNAP_DIR:-}" ]] || { warn "ui_scrollshot_region: SNAP_DIR vide"; return 1; }

  ui_refresh
  local bx1 by1 bx2 by2
  if ! read -r bx1 by1 bx2 by2 < <(ui_get_resid_bounds_topmost "$anchor_resid"); then
    warn "ui_scrollshot_region: anchor not found: $anchor_resid"
    return 1
  fi

  # top crop = y1 - pad_up
  local top_crop=$((by1 - pad_up))
  (( top_crop < 0 )) && top_crop=0

  # centre X sur l'anchor (meilleur pour swiper "dans la zone")
  local x=$(( (bx1 + bx2) / 2 ))

  local ts dir
  ts="$(date +%H-%M-%S)"
  dir="$SNAP_DIR/${ts}_$(safe_tag "$tag")_region"
  mkdir -p "$dir"

  log "scrollshot_region: tag=$tag anchor=$anchor_resid top_crop=$top_crop bottom_crop=$bottom_crop dir=$dir"

  # première capture pour connaitre W/H
  local png0="$dir/000.png"
  ui_screencap_png "$png0"
  local w h
  read -r w h < <(_ui_png_size "$png0")

  # swipe dans la zone "visible après crop"
  local y_start=$(( h - bottom_crop - 30 ))
  local y_end=$(( top_crop + 80 ))
  if (( y_start <= y_end + 50 )); then
    # zone trop petite, on force des valeurs safe
    y_start=$(( h - bottom_crop - 30 ))
    y_end=$(( top_crop + 40 ))
  fi
  (( y_start > h-5 )) && y_start=$((h-5))
  (( y_end < 5 )) && y_end=5

  local prev hash streak=0
  prev="$(_ui_hash_png_center "$png0")"

  # boucle captures suivantes
  local i png
  for ((i=1; i<=max_scroll; i++)); do
    _ui_swipe "$x" "$y_start" "$y_end" "$SCROLLSHOT_SWIPE_MS"
    sleep_s "$settle"

    png="$dir/$(printf '%03d' "$i").png"
    ui_screencap_png "$png" || break

    hash="$(_ui_hash_png_center "$png")"
    if [[ "$hash" == "$prev" ]]; then
      streak=$((streak+1))
      log "scrollshot_region: identical streak=$streak i=$i"
      if (( streak >= SCROLLSHOT_STOP_STREAK )); then
        rm -f "$png" >/dev/null 2>&1 || true
        log "scrollshot_region: stop (no visual change)"
        break
      fi
    else
      streak=0
    fi
    prev="$hash"
  done

  # stitch avec les crops calculés
  local out="$dir/full.png"
  SCROLLSHOT_TOP_CROP="$top_crop" \
  SCROLLSHOT_BOTTOM_CROP="$bottom_crop" \
  SCROLLSHOT_MIN_OV="$SCROLLSHOT_MIN_OV" \
  SCROLLSHOT_MAX_OV="$SCROLLSHOT_MAX_OV" \
  SCROLLSHOT_OV_STEP="$SCROLLSHOT_OV_STEP" \
    ui_scrollshot_stitch "$dir" "$out" >/dev/null

  log "scrollshot_region: stitched -> $out"
  printf '%s\n' "$out"
}
