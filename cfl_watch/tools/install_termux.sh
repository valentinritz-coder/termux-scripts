#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CFL_CODE_DIR="${CFL_CODE_DIR:-$SRC_DIR}"
CFL_CODE_DIR="$(expand_tilde_path "$CFL_CODE_DIR")"
CFL_BASE_DIR="${CFL_BASE_DIR:-$CFL_CODE_DIR}"

if [ -f "$CFL_CODE_DIR/env.sh" ]; then
  . "$CFL_CODE_DIR/env.sh"
fi
if [ -f "$CFL_CODE_DIR/env.local.sh" ]; then
  . "$CFL_CODE_DIR/env.local.sh"
fi

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-$SRC_DIR}")"
CFL_BASE_DIR="${CFL_BASE_DIR:-$CFL_CODE_DIR}"

CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-$HOME/cfl_watch}")"
ARTIFACT_DIR="$(expand_tilde_path "${CFL_ARTIFACT_DIR:-/sdcard/cfl_watch}")"

MODE="install"
DO_PULL=0
RUN_CHECK=0

log(){ printf '[*] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[!!] %s\n' "$*" >&2; exit 1; }

usage(){
  cat <<'USAGE'
Usage: install_termux.sh [options]

Options:
  --update           Git pull (if repo), re-sync code, fix perms, run self-check
  --check            Run self-check at end
  --code-dir PATH    Override install dir (default: $HOME/cfl_watch)
  --artifact-dir PATH Override artifacts dir (default: /sdcard/cfl_watch)
  -h, --help         Show this help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --update)
      MODE="update"
      DO_PULL=1
      RUN_CHECK=1
      shift
      ;;
    --check)
      RUN_CHECK=1
      shift
      ;;
    --code-dir)
      [ $# -ge 2 ] || die "--code-dir requires PATH"
      CODE_DIR="$(expand_tilde_path "$2")"
      shift 2
      ;;
    --artifact-dir)
      [ $# -ge 2 ] || die "--artifact-dir requires PATH"
      ARTIFACT_DIR="$(expand_tilde_path "$2")"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

log "Install mode: $MODE"

log "Install deps (android-tools, python, coreutils, grep, sed, findutils, gawk)"
pkg install -y android-tools python coreutils grep sed findutils gawk >/dev/null 2>&1 \
  || die "pkg install failed (android-tools, python, coreutils, grep, sed, findutils, gawk)"

if [ ! -d "/sdcard" ]; then
  die "/sdcard inaccessible. Run: termux-setup-storage"
fi

log "Ensure artifact dirs: $ARTIFACT_DIR/{runs,logs,tmp}"
mkdir -p "$ARTIFACT_DIR/runs" "$ARTIFACT_DIR/logs" "$ARTIFACT_DIR/tmp"

log "Create/ensure code dir: $CODE_DIR"
mkdir -p "$CODE_DIR"

if [ "$DO_PULL" = "1" ]; then
  if [ -d "$SRC_DIR/.git" ]; then
    log "Update repo: git pull --rebase"
    (cd "$SRC_DIR" && git pull --rebase) || die "git pull failed"
  else
    warn "No .git in $SRC_DIR (skip pull)."
  fi
fi

if [ "$SRC_DIR" = "$CODE_DIR" ]; then
  log "Source == code dir, skip copy"
else
  log "Copy scripts from $SRC_DIR -> $CODE_DIR"
  (cd "$SRC_DIR" && tar -cf - .) | (cd "$CODE_DIR" && tar -xf -)
fi

log "Fix CRLF + permissions inside code dir"
bash "$CODE_DIR/tools/fix_perms_and_crlf.sh" "$CODE_DIR"

if ! command -v adb >/dev/null 2>&1; then
  warn "cfl_snap_watch.sh nécessite adb"
fi

WATCH_UI_DUMP="$CODE_DIR/tools/cfl_snap_watch.sh"
if [ -f "$WATCH_UI_DUMP" ]; then
  log "Ensure cfl_snap_watch.sh is executable"
  chmod +x "$WATCH_UI_DUMP"
else
  warn "cfl_snap_watch.sh not found at $WATCH_UI_DUMP (skip)"
fi

if ! command -v adb >/dev/null 2>&1; then
  warn "adb_session.sh nécessite adb"
fi

ADB_SESSION="$CODE_DIR/tools/adb_session.sh"
if [ -f "$ADB_SESSION" ]; then
  log "Ensure adb_session.sh is executable"
  chmod +x "$ADB_SESSION"
else
  warn "adb_session.sh not found at $ADB_SESSION (skip)"
fi

log "Write /sdcard shims -> $ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"
cat >"$ARTIFACT_DIR/runner.sh" <<'SHIM'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
CFL_CODE_DIR="${CFL_CODE_DIR:-$HOME/cfl_watch}"
exec bash "$CFL_CODE_DIR/runner.sh" "$@"
SHIM
cat >"$ARTIFACT_DIR/console.sh" <<'SHIM'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
CFL_CODE_DIR="${CFL_CODE_DIR:-$HOME/cfl_watch}"
exec bash "$CFL_CODE_DIR/runner.sh" "$@"
SHIM
chmod +x "$ARTIFACT_DIR/runner.sh" "$ARTIFACT_DIR/console.sh" || true

log "Done. Entrypoint: $CODE_DIR/runner.sh (shims in $ARTIFACT_DIR)"
log "Example: ADB_TCP_PORT=37099 bash $CODE_DIR/runner.sh --list"

if [ "$RUN_CHECK" = "1" ]; then
  log "Run self-check"
  bash "$CODE_DIR/tools/self_check.sh"
fi
