export ANDROID_SERIAL=127.0.0.1:5555
bash /sdcard/cfl_watch/map_run.sh --depth 1 --max-screens 10 --max-actions 5 --delay 1.5
ls -1dt /sdcard/cfl_watch/map/* | head -n 1
