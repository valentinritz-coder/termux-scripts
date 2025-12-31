su -c 'command -v runcon >/dev/null && echo "runcon=OK" || echo "runcon=NO"'
su -c 'runcon u:r:shell:s0 id -Z 2>/dev/null || true'
su -c 'runcon u:r:shell:s0 input tap 100 100; echo "rc=$?"'
