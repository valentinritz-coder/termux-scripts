#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}")"
CFL_BASE_DIR="$CFL_CODE_DIR"
TARGET_DIR="$(expand_tilde_path "${1:-$CFL_CODE_DIR}")"

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
