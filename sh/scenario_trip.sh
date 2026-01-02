mkdir -p /sdcard/cfl_watch/{logs,map,tmp}

cat > /sdcard/cfl_watch/scenario_trip.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SER="${ANDROID_SERIAL:-127.0.0.1:37099}"
START_TEXT="${1:-Luxembourg}"
TARGET_TEXT="${2:-Arlon}"
DELAY="${DELAY:-1.2}"

run_root() { su -c "PATH=/system/bin:/system/xbin:/vendor/bin:\$PATH; $1"; }
inject()   { adb -s "$SER" shell "$@"; }
sleep_s()  { sleep "${1:-$DELAY}"; }

tap() { inject input tap "$1" "$2" >/dev/null; }
key() { inject input keyevent "$1" >/dev/null 2>&1 || true; }

type_text() {
  local t="$1"
  t="${t//\'/}"      # supprime apostrophes (shell)
  t="${t// /%s}"     # espaces -> %s
  inject input text "$t" >/dev/null
}

dump_xml() {
  local out="$1"
  run_root "uiautomator dump --compressed '$out'" >/dev/null 2>&1 || true
}

echo "[*] device=$SER"
TMP="/sdcard/cfl_watch/tmp"
mkdir -p "$TMP"
XML="$TMP/ui_after.xml"

echo "[*] Tap destination"
tap 518 561
sleep_s 0.8
type_text "$TARGET_TEXT"
sleep_s 0.4
key 66
sleep_s 1.0

echo "[*] Tap start"
tap 518 407
sleep_s 0.8
type_text "$START_TEXT"
sleep_s 0.4
key 66
sleep_s 1.0

echo "[*] Tap search"
tap 970 561
sleep_s 2.2

dump_xml "$XML"
if grep -qi "Results" "$XML" 2>/dev/null; then
  echo "[+] Results detected"
  exit 0
fi

echo "[!] Results not detected in dump (possible overlay/text-poor screen)"
exit 1
SH

chmod +x /sdcard/cfl_watch/scenario_trip.sh
sed -i 's/\r$//' /sdcard/cfl_watch/scenario_trip.sh 2>/dev/null || true
