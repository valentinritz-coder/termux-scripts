python - <<'PY'
import re
from pathlib import Path

p = Path("/sdcard/cfl_watch/map.sh")
s = p.read_text(encoding="utf-8", errors="replace")

old = r"""  local i=0
  while IFS=$'\t' read -r x y label; do
    [ -z "${x:-}" ] && continue
    i=$((i+1))
    echo "    -> tap#$i ($x,$y) $label"
    run_root "input tap $x $y" >/dev/null 2>&1 || true
    sleep "$DELAY"

    explore $((depth-1))

    # Back to previous
    run_root "input keyevent 4" >/dev/null 2>&1 || true
    sleep 0.8

    # Stop if too many screens
    local c
    c=$(cat "$COUNT_FILE")
    if [ "$c" -ge "$MAX_SCREENS" ]; then
      break
    fi
  done < "$actions_file"
"""

new = r"""  local i=0
  # Base hash of the current (saved) screen
  local base_hash="$h"

  while IFS=$'\t' read -r x y label; do
    [ -z "${x:-}" ] && continue
    i=$((i+1))
    echo "    -> tap#$i ($x,$y) $label"

    run_root "input tap $x $y" >/dev/null 2>&1 || true
    sleep "$DELAY"

    # Capture after tap and compare hash: only BACK if screen changed
    local tmp2_xml="$MAP_DIR/tmp/after.xml"
    local tmp2_png="$MAP_DIR/tmp/after.png"

    if capture_screen "$tmp2_xml" "$tmp2_png"; then
      local after_hash
      after_hash="$(hash_screen "$tmp2_xml")"

      if [ "$after_hash" = "$base_hash" ]; then
        echo "       (no screen change -> no BACK)"
        continue
      fi

      # Screen changed -> explore deeper
      explore $((depth-1))

      # Return to previous screen ONCE
      run_root "input keyevent 4" >/dev/null 2>&1 || true
      sleep 0.8

      # Refresh base hash after going back
      if capture_screen "$tmp2_xml" "$tmp2_png"; then
        base_hash="$(hash_screen "$tmp2_xml")"
      fi
    else
      echo "       (capture failed after tap)"
    fi

    # Stop if too many screens
    local c
    c=$(cat "$COUNT_FILE")
    if [ "$c" -ge "$MAX_SCREENS" ]; then
      break
    fi
  done < "$actions_file"
"""

if old not in s:
    raise SystemExit("Je n'ai pas trouvé le bloc de boucle à remplacer. Ton map.sh a probablement changé.")
s = s.replace(old, new)

p.write_text(s, encoding="utf-8")
print("OK patched:", p)
PY
