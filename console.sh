ls -l /system/bin/input || true

su -c 'ls -l /system/bin/input; /system/bin/input tap 100 100; echo "rc=$?"' || true

su -c 'runcon u:r:shell:s0 /system/bin/input tap 100 100; echo "rc=$?"' || true
