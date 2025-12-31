python - <<'PY'
import re
from pathlib import Path

p = Path("/sdcard/cfl_watch/map.sh")
s = p.read_text(encoding="utf-8", errors="replace")

# (Optional) focus detection: more reliable than dumpsys window on many devices
s = re.sub(
    r"get_focus_pkg\(\)\s*\{\n.*?\n\}",
    """get_focus_pkg() {
  run_root "dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' -m 1" 2>/dev/null \
    | sed -n 's/.* \\([a-zA-Z0-9_.]\\+\\)\\/.*/\\1/p' | head -n 1
}""",
    s,
    flags=re.S
)

# Replace the tap loop: only press BACK if the screen actually changed
pattern = r"""
(\s+local\s+i=0\s*\n)
(\s+while\s+IFS=\$'\\t'\s+read\s+-r\s+x\s+y\s+label;\s+do\n)
.*?
(\s+done\s+<\s+"\$actions_file"\n)
"""
m = re.search(pattern, s, flags=re.S|re.X)
if not m:
    raise SystemExit("Could not locate actions loop to patch")

replacement = m.group(1) + r"""  # Base hash of current screen (the one we just saved)
  local base_hash
  base_hash="$(hash_screen "$scr_dir/ui.xml")" || base_hash=""

  while IFS=$'\t' read -r x y label; do
    [ -z "${x:-}" ] && continue
    i=$((i+1))
    echo "    -> tap#$i ($x,$y) $label"

    run_root "input tap $x $y" >/dev/null 2>&1 || true
    sleep "$DELAY"

    # Capture after tap to see if anything actually changed
    local tmp2_xml="$MAP_DIR/tmp/after.xml"
    local tmp2_png="$MAP_DIR/tmp/after.png"
    if capture_screen "$tmp2_xml" "$tmp2_png"; then
      local after_hash
      after_hash="$(hash_screen "$tmp2_xml")"

      if [ "$after_hash" = "$base_hash" ]; then
        echo "       (no screen change -> no BACK)"
        continue
      fi

      # Screen changed -> explore one level deeper
      explore $((depth-1))

      # Now go back ONCE (because we really changed screen)
      run_root "input keyevent 4" >/dev/null 2>&1 || true
      sleep 0.8

      # Refresh base hash after going back
      if capture_screen "$tmp2_xml" "$tmp2_png"; then
        base_hash="$(hash_screen "$tmp2_xml")"
      fi
    else
      echo "       (capture failed after tap)"
    fi

    local c
    c=$(cat "$COUNT_FILE")
    if [ "$c" -ge "$MAX_SCREENS" ]; then
      break
    fi
  done < "$actions_file"
"""
s = s[:m.start()] + replacement + s[m.end():]

p.write_text(s, encoding="utf-8")
print("Patched:", p)
PY
