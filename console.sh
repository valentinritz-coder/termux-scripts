command -v input
ls -l "$(command -v input)" || true

su -c 'command -v input; ls -l "$(command -v input)" || true'
su -c 'ls -l /system/bin/input || true'
