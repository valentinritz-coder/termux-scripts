#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}")"
ARTIFACT_DIR="$(expand_tilde_path "${CFL_ARTIFACT_DIR:-/sdcard/cfl_watch}")"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log(){ printf '[*] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[!!] %s\n' "$*" >&2; exit 1; }

log "Install deps (android-tools, python)"
pkg install -y android-tools python >/dev/null 2>&1 || die "pkg install failed (android-tools, python)"

log "Create code dir: $CODE_DIR"
mkdir -p "$CODE_DIR"

log "Copy scripts from $SRC_DIR -> $CODE_DIR"
(cd "$SRC_DIR" && tar -cf - .) | (cd "$CODE_DIR" && tar -xf -)

log "Ensure artifact dirs: $ARTIFACT_DIR/{runs,logs}"
mkdir -p "$ARTIFACT_DIR/runs" "$ARTIFACT_DIR/logs"

log "Ensure tmp dir: $CODE_DIR/tmp"
mkdir -p "$CODE_DIR/tmp"

log "Fix CRLF + permissions inside code dir"
bash "$CODE_DIR/tools/fix_perms_and_crlf.sh" "$CODE_DIR"

log "Write /sdcard shims -> $ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"
cat >"$ARTIFACT_DIR/runner.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
CFL_CODE_DIR="${CFL_CODE_DIR:-$HOME/cfl_watch}"
exec bash "$CFL_CODE_DIR/runner.sh" "$@"
EOF
cat >"$ARTIFACT_DIR/console.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
CFL_CODE_DIR="${CFL_CODE_DIR:-$HOME/cfl_watch}"
exec bash "$CFL_CODE_DIR/runner.sh" "$@"
EOF

log "Done. Entrypoint: $CODE_DIR/runner.sh (shims remain in $ARTIFACT_DIR)"
log "Example: ADB_TCP_PORT=37099 bash $CODE_DIR/runner.sh --list"
