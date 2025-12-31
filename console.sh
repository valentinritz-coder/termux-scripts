su -c 'getprop service.adb.tcp.port; getprop init.svc.adbd'
su -c 'ss -ltn 2>/dev/null | grep -E ":(5555)\b" || netstat -ltn 2>/dev/null | grep -E ":(5555)\b" || echo "NO_LISTENER_5555"'
