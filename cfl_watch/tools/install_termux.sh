#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

TARGET="${CFL_BASE_DIR:-/sdcard/cfl_watch}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log(){ printf '[*] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }

die(){ printf '[!!] %s\n' "$*" >&2; exit 1; }

log "Install deps (android-tools, python)"
pkg install -y android-tools python >/dev/null 2>&1 || die "pkg install failed (android-tools, python)"

log "Create target dir: $TARGET"
mkdir -p "$TARGET"

log "Copy scripts from $SRC_DIR to $TARGET"
(cd "$SRC_DIR" && tar -cf - .) | (cd "$TARGET" && tar -xf -)

log "Ensure work dirs"
mkdir -p "$TARGET"/logs "$TARGET"/runs "$TARGET"/tmp "$TARGET"/scenarios "$TARGET"/lib "$TARGET"/tools

log "Fix CRLF + permissions"
bash "$TARGET/tools/fix_perms_and_crlf.sh" "$TARGET"

log "Ready. Entrypoint: $TARGET/runner.sh"
log "Example: ADB_TCP_PORT=37099 bash $TARGET/runner.sh --list"
