#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

CFL_BASE_DIR="${CFL_BASE_DIR:-/sdcard/cfl_watch}"
TARGET_DIR="${1:-$CFL_BASE_DIR}"

log(){ printf '[*] %s\n' "$*"; }

log "Fix CRLF + permissions under $TARGET_DIR"

# Remove CRLF on common text files
find "$TARGET_DIR" -type f \( -name "*.sh" -o -name "*.py" -o -name "*.md" -o -name "*.txt" -o -name "*.html" \) -print0 \
| while IFS= read -r -d '' file; do
    sed -i 's/\r$//' "$file" || true
  done

chmod +x "$TARGET_DIR/runner.sh" 2>/dev/null || true
chmod +x "$TARGET_DIR/console.sh" 2>/dev/null || true
chmod +x "$TARGET_DIR"/lib/*.sh "$TARGET_DIR"/scenarios/*.sh "$TARGET_DIR"/tools/*.sh 2>/dev/null || true

log "Done"
