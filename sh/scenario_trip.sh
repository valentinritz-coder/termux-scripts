cat > /sdcard/cfl_watch/scenario_trip.sh <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SER="${ANDROID_SERIAL:-127.0.0.1:5555}"
START_TEXT="${1:-Luxembourg}"
TARGET_TEXT="${2:-Arlon}"
DELAY="${DELAY:-1.2}"

run_root() { su -c "PATH=/system/bin:/system/xbin:/vendor/bin:\$PATH; $1"; }

inject() {
  # no redirection here; let errors show up in logs if adb is not connected
  adb -s "$SER" shell "$@"
}

sleep_s() { sleep "${1:-$DELAY}"; }

tap() { inject input tap "$1" "$2" >/dev/null; }
key() { inject input keyevent "$1" >/dev/null 2>&1 || true; }

type_text() {
  local t="$1"
  t="${t//\'/}"      # drop apostrophes (shell safety)
  t="${t// /%s}"     # spaces for input
  inject input text "$t" >/dev/null
}

dump_xml() {
  local out="$1"
  run_root "uiautomator dump --compressed '$out'" >/dev/null 2>&1 || true
}

has_text() { grep -qi "$2" "$1"; }

echo "[*] Using device: $SER"
echo "[*] START='$START_TEXT' TARGET='$TARGET_TEXT'"

TMP="/sdcard/cfl_watch/tmp"
mkdir -p "$TMP"
XML="$TMP/ui_after.xml"

# Destination
echo "[*] Tap destination"
tap 518 561
sleep_s 0.8
type_text "$TARGET_TEXT"
sleep_s 0.4
key 66
sleep_s 1.0

# Start
echo "[*] Tap start"
tap 518 407
sleep_s 0.8
type_text "$START_TEXT"
sleep_s 0.4
key 66
sleep_s 1.0

# Search button (bounds [926,517][1014,605] -> center ~ 970,561)
echo "[*] Tap search"
tap 970 561
sleep_s 2.2

dump_xml "$XML"
if has_text "$XML" "Results"; then
  echo "[+] Reached Results (detected in dump)"
  exit 0
fi

ACT="$(run_root "dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' -m 1" 2>/dev/null || true)"
echo "[*] Resumed activity: $ACT"
echo "[!] Could not confirm Results via dump (might be overlay/text-poor)."
exit 1
SH

chmod +x /sdcard/cfl_watch/scenario_trip.sh
