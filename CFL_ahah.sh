mkdir -p "$HOME/.shortcuts"

cat > "$HOME/.shortcuts/CFL_console" <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

URL="https://raw.githubusercontent.com/valentinritz-coder/termux-scripts/main/console.sh"

BASE="/sdcard/cfl_watch"
TMP="$BASE/tmp/console.sh"
LOG="$BASE/logs/console_$(date +%Y-%m-%d_%H-%M-%S).log"

mkdir -p "$BASE"/{logs,tmp,map}

echo "=== FETCH $URL ===" >"$LOG"
curl -fsSL "$URL" -o "$TMP" >>"$LOG" 2>&1

# Normalise CRLF (au cas où)
sed -i 's/\r$//' "$TMP" 2>/dev/null || true
chmod +x "$TMP" 2>/dev/null || true

echo "=== EXEC $TMP ===" >>"$LOG"
bash -x "$TMP" >>"$LOG" 2>&1

echo "=== DONE ===" >>"$LOG"
echo "LOG=$LOG"
SH

chmod +x "$HOME/.shortcuts/CFL_console"
