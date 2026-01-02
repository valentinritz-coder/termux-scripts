#!/data/data/com.termux/files/usr/bin/bash

# Shared path helpers for CFL scripts.

# Expand a leading tilde so user-provided paths like ~/something resolve
# correctly without relying on eval.
expand_tilde_path(){
  case "${1:-}" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "${1/#\~/$HOME}" ;;
    *) printf '%s' "${1:-}" ;;
  esac
}
