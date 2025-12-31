cat > /sdcard/cfl_watch/scenario_trip.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PKG="de.hafas.android.cfl"
START_TEXT="${1:-Luxembourg}"
TARGET_TEXT="${2:-Arlon}"
DELAY=1.2

run_root() {
  if command -v su >/dev/null 2>&1; then
    su -c "PATH=/system/bin:/system/xbin:/vendor/bin:\$PATH; $1"
  else
    sh -c "$1"
  fi
}

# wait a bit for UI to settle
sleep_s() { sleep "${1:-$DELAY}"; }

dump_xml() {
  local out="$1"
  run_root "uiautomator dump --compressed '$out'" >/dev/null 2>&1
}

has_text() {
  local xml="$1" ; local pat="$2"
  grep -qi "$pat" "$xml"
}

# tap by coordinate (from your actions.txt)
tap() { run_root "input tap $1 $2" >/dev/null 2>&1; }

# types text into currently focused input
type_text() {
  # input text has issues with spaces; replace with %s (works often) then fallback
  local t="$1"
  local t2="${t// /%s}"
  run_root "input text '$t2'" >/dev/null 2>&1 || true
}

key() { run_root "input keyevent $1" >/dev/null 2>&1 || true; }

# ---- Start: assume CFL already launched and on Home
TMP="/sdcard/cfl_watch/tmp"
mkdir -p "$TMP"
XML1="$TMP/ui1.xml"
XML2="$TMP/ui2.xml"

echo "[*] Tap destination field"
tap 518 561
sleep_s 1.0
# try to force keyboard/focus
key 61   # TAB (often moves focus)
sleep_s 0.5
type_text "$TARGET_TEXT"
sleep_s 0.8
key 66   # ENTER
sleep_s 1.0

dump_xml "$XML1" || true
if has_text "$XML1" "Select destination"; then
  echo "[!] Still looks like Home dump. Overlay might be invisible to uiautomator."
fi

echo "[*] Tap start field"
tap 518 407
sleep_s 1.0
key 61
sleep_s 0.5
type_text "$START_TEXT"
sleep_s 0.8
key 66
sleep_s 1.0

dump_xml "$XML2" || true

echo "[*] Tap search button"
# search icon center: bounds [926,517][1014,605] -> ~ (970,561)
tap 970 561
sleep_s 2.0

# verify we reached Results (toolbar text often becomes Results)
dump_xml "$XML2" || true
if has_text "$XML2" "Results"; then
  echo "[+] Reached Results (detected in dump)"
  exit 0
fi

# fallback: check resumed activity
ACT="$(run_root "dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' -m 1" 2>/dev/null || true)"
echo "[*] Resumed activity: $ACT"
echo "[!] Could not confirm Results via dump. Might still be Results but not visible in XML."
exit 1
SH

chmod +x /sdcard/cfl_watch/scenario_trip.sh
mkdir -p /sdcard/cfl_watch/tmp
