cat > /sdcard/cfl_watch/setup.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE="${CFL_WATCH_BASE:-/sdcard/cfl_watch}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1"
    return 1
  }
}

echo "[*] CFL Watch setup"
mkdir -p "$BASE"/{runs,baseline,reports,zips,tmp,logs}
touch "$BASE/.nomedia" 2>/dev/null || true

# Termux storage
if [ ! -d /sdcard ] && [ ! -d /storage/emulated/0 ]; then
  echo "[!] /sdcard not accessible. Run: termux-setup-storage"
  exit 1
fi

# Basic deps
missing=0
for c in bash date ls find grep sed awk diff python zip; do
  command -v "$c" >/dev/null 2>&1 || { echo "[!] Missing: $c"; missing=1; }
done
if [ "$missing" -eq 1 ]; then
  echo
  echo "Install deps with:"
  echo "  pkg install -y bash coreutils findutils grep sed gawk diffutils python zip"
  exit 1
fi

# Root check (optional but recommended)
if command -v su >/dev/null 2>&1; then
  if su -c id >/dev/null 2>&1; then
    echo "[+] Root OK (su works)"
  else
    echo "[!] su exists but root check failed (Magisk prompt? policy?)"
  fi
else
  echo "[!] su not found. Some captures may still work, but root is recommended."
fi

# uiautomator / screencap presence check
if command -v uiautomator >/dev/null 2>&1; then
  echo "[+] uiautomator found in PATH"
elif [ -x /system/bin/uiautomator ]; then
  echo "[+] uiautomator exists at /system/bin/uiautomator"
else
  echo "[!] uiautomator not found (unexpected on stock Android)."
fi

if command -v screencap >/dev/null 2>&1; then
  echo "[+] screencap found in PATH"
elif [ -x /system/bin/screencap ]; then
  echo "[+] screencap exists at /system/bin/screencap"
else
  echo "[!] screencap not found (unexpected)."
fi

# Create default config (if not exists)
CFG="$BASE/config.sh"
if [ ! -f "$CFG" ]; then
  cat > "$CFG" <<'CFGSH'
# CFL Watch config (sourced by snap.sh)

# Consider UI text "weak" if extracted lines are below this:
CFL_WEAK_TEXT_MIN_LINES=8

# Normalization knobs (1=on, 0=off)
CFL_NORM_MASK_TIMES=1
CFL_NORM_MASK_DATES=1
CFL_NORM_MASK_DURATIONS=1
CFL_NORM_MASK_NUMBERS=1

# Extra regex-like replacements are implemented in Python inside snap.sh (edit there if needed).
CFGSH
  echo "[+] Wrote default config: $CFG"
else
  echo "[=] Config exists: $CFG"
fi

echo "[+] Base folders:"
ls -1 "$BASE" | sed 's/^/  - /'

echo
echo "Next:"
echo "  bash $BASE/snap.sh itinerary"
SH
chmod +x /sdcard/cfl_watch/setup.sh 2>/dev/null || true
