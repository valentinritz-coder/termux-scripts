SER="192.168.118.150:39973"

adb kill-server >/dev/null 2>&1 || true
adb start-server

adb connect "$SER"
adb devices -l
adb -s "$SER" shell id -Z
