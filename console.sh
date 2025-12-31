adb kill-server 2>/dev/null || true
pkill -f adb 2>/dev/null || true
adb start-server
adb devices -l
