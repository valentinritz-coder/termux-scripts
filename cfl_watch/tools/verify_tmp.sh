#!/data/data/com.termux/files/usr/bin/bash
# Vérifie que CFL_TMP_DIR est accessible côté Termux et adb, et que uiautomator dump produit un XML non vide.
set -euo pipefail

fail(){ printf 'FAIL: %s\n' "$1" >&2; exit "${2:-1}"; }
info(){ printf '[*] %s\n' "$1"; }
pass(){ printf 'OK: %s\n' "$1"; }

status_tmp="FAIL"
status_local="FAIL"
status_adb="FAIL"
status_dump="FAIL"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/path.sh"

CFL_CODE_DIR="$(expand_tilde_path "${CFL_CODE_DIR:-${CFL_BASE_DIR:-$HOME/cfl_watch}}")"
CFL_BASE_DIR="$CFL_CODE_DIR"
. "$CFL_CODE_DIR/lib/common.sh"

cleanup(){
  inject sh -c "rm -f '$CFL_TMP_DIR/local_ok' '$CFL_TMP_DIR/adb_ok' '$CFL_TMP_DIR/_codex_dump.xml'" >/dev/null 2>&1 || true
  rm -f "$CFL_TMP_DIR/local_ok" "$CFL_TMP_DIR/_codex_dump.xml" "$CFL_TMP_DIR/adb_ok" >/dev/null 2>&1 || true
}

print_recap(){
  printf '\nRecap:\n'
  printf '  tmp placement : %s\n' "$status_tmp"
  printf '  local write   : %s\n' "$status_local"
  printf '  adb write     : %s\n' "$status_adb"
  printf '  uiautomator   : %s\n' "$status_dump"
}

on_exit(){
  rc=$?
  cleanup
  print_recap
  exit "$rc"
}

trap on_exit EXIT

info "CFL_CODE_DIR=$CFL_CODE_DIR"
info "CFL_ARTIFACT_DIR=$CFL_ARTIFACT_DIR"
info "CFL_TMP_DIR=$CFL_TMP_DIR"
info "CFL_SERIAL=$CFL_SERIAL"

if [[ "$CFL_TMP_DIR" == /data/data/com.termux/* ]]; then
  fail "CFL_TMP_DIR est dans /data/data/com.termux. Choisissez un chemin sur /sdcard (exit 2)." 2
fi

status_tmp="PASS"
if [[ "$CFL_TMP_DIR" == /sdcard/* ]]; then
  pass "CFL_TMP_DIR est sur sdcard."
else
  info "CFL_TMP_DIR n'est pas sur sdcard. Assurez-vous que le chemin est accessible via adb shell."
fi

adb start-server >/dev/null 2>&1 || true
if ! inject sh -c "true" >/dev/null 2>&1; then
  fail "adb shell inaccessible sur $CFL_SERIAL" 3
fi

info "Device info:"
inject sh -c "id" || true
inject sh -c "getprop ro.product.model | head -n1" || true
inject sh -c "getprop ro.build.version.release | head -n1" || true

info "Test d'écriture côté Termux..."
mkdir -p "$CFL_TMP_DIR" || fail "Impossible de créer $CFL_TMP_DIR côté Termux" 3
touch "$CFL_TMP_DIR/local_ok" || fail "Impossible d'écrire local_ok dans $CFL_TMP_DIR" 3
status_local="PASS"

info "Test d'écriture via adb shell..."
if ! inject sh -c "mkdir -p '$CFL_TMP_DIR'" >/dev/null 2>&1; then
  fail "mkdir -p côté adb a échoué" 3
fi
if ! inject sh -c "echo adb_ok > '$CFL_TMP_DIR/adb_ok'" >/dev/null 2>&1; then
  fail "Impossible d'écrire adb_ok via adb" 3
fi
if ! inject sh -c "ls -l '$CFL_TMP_DIR'"; then
  fail "Impossible de lister $CFL_TMP_DIR via adb" 3
fi
status_adb="PASS"
pass "Écriture locale et adb OK."

info "Test uiautomator dump..."
dump_path="$CFL_TMP_DIR/_codex_dump.xml"
if ! inject sh -c "rm -f '$dump_path'" >/dev/null 2>&1; then
  fail "Impossible de supprimer $dump_path via adb" 4
fi
if ! inject sh -c "uiautomator dump --compressed '$dump_path'"; then
  fail "uiautomator dump a échoué" 4
fi
if ! inject sh -c "test -s '$dump_path'" >/dev/null 2>&1; then
  fail "Dump vide ou absent: $dump_path" 4
fi
if ! inject sh -c "grep -q '<hierarchy' '$dump_path'" >/dev/null 2>&1; then
  fail "Le dump ne contient pas <hierarchy" 4
fi
status_dump="PASS"
pass "uiautomator dump OK: $dump_path"

pass "Tous les checks sont passés."
exit 0
