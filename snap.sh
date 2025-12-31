cat > /sdcard/cfl_watch/snap.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="${CFL_WATCH_BASE:-/sdcard/cfl_watch}"
CFG="$BASE/config.sh"
[ -f "$CFG" ] && source "$CFG"

# Defaults
: "${CFL_WEAK_TEXT_MIN_LINES:=8}"
: "${CFL_NORM_MASK_TIMES:=1}"
: "${CFL_NORM_MASK_DATES:=1}"
: "${CFL_NORM_MASK_DURATIONS:=1}"
: "${CFL_NORM_MASK_NUMBERS:=1}"

usage() {
  cat <<EOF
Usage:
  bash $BASE/snap.sh <label> [--set-baseline] [--note "text"]

Creates per-run folder with:
  ui.xml, screen.png, texts.txt, texts.norm.txt, diff.txt (if previous), summary.txt
EOF
}

if [ "${1:-}" = "" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

LABEL="$1"; shift
SET_BASELINE=0
NOTE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --set-baseline) SET_BASELINE=1; shift ;;
    --note) NOTE="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

timestamp() {
  # coreutils date supports %N in Termux; fallback if not
  if date +"%Y-%m-%d_%H-%M-%S_%3N" >/dev/null 2>&1; then
    date +"%Y-%m-%d_%H-%M-%S_%3N"
  else
    date +"%Y-%m-%d_%H-%M-%S"
  fi
}

run_root() {
  # Usage: run_root "command string"
  if command -v su >/dev/null 2>&1; then
    su -c "$1"
  else
    sh -c "$1"
  fi
}

LAB_DIR="$BASE/runs/$LABEL"
RUN_ID="$(timestamp)"
RUN_DIR="$LAB_DIR/$RUN_ID"
mkdir -p "$RUN_DIR" "$BASE/tmp"

UI_XML="$RUN_DIR/ui.xml"
SCREEN_PNG="$RUN_DIR/screen.png"
TEXTS_TXT="$RUN_DIR/texts.txt"
TEXTS_NORM="$RUN_DIR/texts.norm.txt"
DIFF_TXT="$RUN_DIR/diff.txt"
SUMMARY_TXT="$RUN_DIR/summary.txt"
META_TXT="$RUN_DIR/meta.txt"

# Meta (best effort)
{
  echo "label=$LABEL"
  echo "run_id=$RUN_ID"
  echo "run_dir=$RUN_DIR"
  echo "android_release=$(getprop ro.build.version.release 2>/dev/null || true)"
  echo "android_sdk=$(getprop ro.build.version.sdk 2>/dev/null || true)"
  echo "model=$(getprop ro.product.model 2>/dev/null || true)"
  echo "timestamp_epoch=$(date +%s)"
  echo "note=$NOTE"
  echo
  echo "== Focus =="
  run_root "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp' -m 2" 2>/dev/null || true
  echo
  echo "== Top activity (trimmed) =="
  run_root "dumpsys activity top | head -n 60" 2>/dev/null || true
} > "$META_TXT" || true

# 1) UI dump
UI_OK=0
if run_root "uiautomator dump --compressed '$UI_XML'" >/dev/null 2>&1; then
  UI_OK=1
elif uiautomator dump --compressed "$UI_XML" >/dev/null 2>&1; then
  UI_OK=1
else
  UI_OK=0
fi

# 2) Screenshot
SC_OK=0
if run_root "screencap -p '$SCREEN_PNG'" >/dev/null 2>&1; then
  SC_OK=1
elif screencap -p "$SCREEN_PNG" >/dev/null 2>&1; then
  SC_OK=1
else
  SC_OK=0
fi

# 3) Extract visible texts (text + content-desc)
if [ "$UI_OK" -eq 1 ] && [ -s "$UI_XML" ]; then
  python - <<PY > "$TEXTS_TXT"
import xml.etree.ElementTree as ET

ui_xml = r"$UI_XML"
try:
    tree = ET.parse(ui_xml)
    root = tree.getroot()
except Exception as e:
    print(f"__PARSE_ERROR__\t{e}")
    raise SystemExit(0)

lines = []
for node in root.iter("node"):
    t = (node.attrib.get("text") or "").strip()
    d = (node.attrib.get("content-desc") or "").strip()
    rid = (node.attrib.get("resource-id") or "").strip()
    cls = (node.attrib.get("class") or "").strip()
    pkg = (node.attrib.get("package") or "").strip()

    if not t and not d:
        continue

    # canonical line: stable diff (ordering changes won't explode your diff)
    lines.append(f"{pkg}\t{rid}\t{cls}\t{t}\t{d}")

# de-dupe + sort for stability
for s in sorted(set(lines)):
    print(s)
PY
else
  echo "__UI_DUMP_MISSING_OR_EMPTY__" > "$TEXTS_TXT"
fi

# 4) Normalization (mask times, dates, durations, numbers)
python - <<PY > "$TEXTS_NORM"
import re

mask_times = int(r"${CFL_NORM_MASK_TIMES}")
mask_dates = int(r"${CFL_NORM_MASK_DATES}")
mask_durs  = int(r"${CFL_NORM_MASK_DURATIONS}")
mask_nums  = int(r"${CFL_NORM_MASK_NUMBERS}")

in_path = r"$TEXTS_TXT"

time_re_1 = re.compile(r"\b([01]?\d|2[0-3])[:h][0-5]\d([:][0-5]\d)?\b")
date_re_1 = re.compile(r"\b\d{4}-\d{2}-\d{2}\b")
date_re_2 = re.compile(r"\b\d{1,2}[\/\.-]\d{1,2}([\/\.-]\d{2,4})?\b")
dur_re_1  = re.compile(r"\b\d+\s?(min|mn|m|h|hr|s)\b", re.IGNORECASE)
num_re_1  = re.compile(r"\b\d+\b")
num_re_2  = re.compile(r"\b\d+[.,]\d+\b")  # decimals like 1,2 or 1.2

def norm_line(s: str) -> str:
    s = s.strip()
    if not s:
        return s
    # normalize whitespace
    s = re.sub(r"\s+", " ", s)

    if mask_times:
        s = time_re_1.sub("<TIME>", s)

    if mask_dates:
        s = date_re_1.sub("<DATE>", s)
        s = date_re_2.sub("<DATE>", s)

    if mask_durs:
        s = dur_re_1.sub("<DUR>", s)

    if mask_nums:
        # decimals first to avoid splitting
        s = num_re_2.sub("<NUM>", s)
        s = num_re_1.sub("<NUM>", s)

    # common dynamic tokens in mobility apps
    s = re.sub(r"\b(aujourd'hui|demain|hier)\b", "<REL_DAY>", s, flags=re.IGNORECASE)

    return s

with open(in_path, "r", encoding="utf-8", errors="replace") as f:
    out = [norm_line(line) for line in f if line.strip()]

# drop empty lines after norm
out = [x for x in out if x]

# stable output
for s in sorted(set(out)):
    print(s)
PY

# Weak text detection
TEXT_LINES=$(wc -l < "$TEXTS_TXT" 2>/dev/null || echo 0)
NORM_LINES=$(wc -l < "$TEXTS_NORM" 2>/dev/null || echo 0)
TEXT_CHARS=$(wc -c < "$TEXTS_TXT" 2>/dev/null || echo 0)
LOW_TEXT=0
if [ "$NORM_LINES" -lt "${CFL_WEAK_TEXT_MIN_LINES}" ]; then
  LOW_TEXT=1
fi

# 5) Diff vs previous & baseline
PREV_DIR=""
if [ -d "$LAB_DIR" ]; then
  # newest first; current is first, previous is second
  PREV_DIR=$(ls -1dt "$LAB_DIR"/*/ 2>/dev/null | sed -n '2p' | sed 's:/*$::' || true)
fi

BASE_DIR="$BASE/baseline/$LABEL"
BASE_NORM="$BASE_DIR/texts.norm.txt"
mkdir -p "$BASE_DIR"

{
  echo "=== DIFF (normalized) ==="
  echo "label=$LABEL"
  echo "run=$RUN_ID"
  echo

  if [ -n "$PREV_DIR" ] && [ -f "$PREV_DIR/texts.norm.txt" ]; then
    echo "## vs previous"
    diff -u "$PREV_DIR/texts.norm.txt" "$TEXTS_NORM" || true
    echo
  else
    echo "## vs previous"
    echo "(no previous run)"
    echo
  fi

  if [ -f "$BASE_NORM" ]; then
    echo "## vs baseline"
    diff -u "$BASE_NORM" "$TEXTS_NORM" || true
    echo
  else
    echo "## vs baseline"
    echo "(no baseline for this label yet)"
    echo
  fi
} > "$DIFF_TXT"

# Diff stats
diff_prev_adds=0; diff_prev_dels=0
diff_base_adds=0; diff_base_dels=0

if [ -n "$PREV_DIR" ] && [ -f "$PREV_DIR/texts.norm.txt" ]; then
  diff_prev_adds=$(diff -u "$PREV_DIR/texts.norm.txt" "$TEXTS_NORM" | grep -E '^\+[^+]' | wc -l | tr -d ' ')
  diff_prev_dels=$(diff -u "$PREV_DIR/texts.norm.txt" "$TEXTS_NORM" | grep -E '^\-[^-]' | wc -l | tr -d ' ')
fi
if [ -f "$BASE_NORM" ]; then
  diff_base_adds=$(diff -u "$BASE_NORM" "$TEXTS_NORM" | grep -E '^\+[^+]' | wc -l | tr -d ' ')
  diff_base_dels=$(diff -u "$BASE_NORM" "$TEXTS_NORM" | grep -E '^\-[^-]' | wc -l | tr -d ' ')
fi

# 6) Summary
{
  echo "label=$LABEL"
  echo "run_id=$RUN_ID"
  echo "run_dir=$RUN_DIR"
  echo "ui_dump_ok=$UI_OK"
  echo "screencap_ok=$SC_OK"
  echo "texts_lines=$TEXT_LINES"
  echo "texts_chars=$TEXT_CHARS"
  echo "norm_lines=$NORM_LINES"
  echo "low_text=$LOW_TEXT"
  echo "prev_dir=$PREV_DIR"
  echo "baseline_present=$([ -f "$BASE_NORM" ] && echo 1 || echo 0)"
  echo "diff_prev_adds=$diff_prev_adds"
  echo "diff_prev_dels=$diff_prev_dels"
  echo "diff_base_adds=$diff_base_adds"
  echo "diff_base_dels=$diff_base_dels"
  echo "note=$NOTE"
  echo
  echo "files:"
  echo "  ui.xml=$UI_XML"
  echo "  screen.png=$SCREEN_PNG"
  echo "  texts.txt=$TEXTS_TXT"
  echo "  texts.norm.txt=$TEXTS_NORM"
  echo "  diff.txt=$DIFF_TXT"
  echo "  meta.txt=$META_TXT"
} > "$SUMMARY_TXT"

# Update "latest" pointer
echo "$RUN_DIR" > "$LAB_DIR/LATEST"

# Optional: set baseline to this run
if [ "$SET_BASELINE" -eq 1 ]; then
  cp -f "$TEXTS_NORM" "$BASE_NORM"
  echo "[+] Baseline updated: $BASE_NORM"
fi

# Console recap
echo "[+] $LABEL -> $RUN_DIR"
echo "    ui_dump_ok=$UI_OK  screencap_ok=$SC_OK  low_text=$LOW_TEXT"
echo "    diff_prev +$diff_prev_adds -$diff_prev_dels | diff_base +$diff_base_adds -$diff_base_dels"
SH
chmod +x /sdcard/cfl_watch/snap.sh 2>/dev/null || true
