#!/usr/bin/env bash
# Lean / peek test. See tests/lean_test.gd.
set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/lean.log"
echo "=== lean / peek test ==="
"$GODOT" --headless --path "$PROJ" -s tests/lean_test.gd >"$LOG" 2>&1 &
PID=$!
( sleep 35 && kill -9 $PID 2>/dev/null && echo "[killed after 35s]" >>"$LOG" ) &
KILLER=$!
wait $PID 2>/dev/null
kill "$KILLER" 2>/dev/null
echo "--- log tail ---"; tail -12 "$LOG"
echo "--- result ---"
if grep -q "^  PASS — " "$LOG"; then echo "PASS"; exit 0
elif grep -q "^  FAIL — " "$LOG"; then echo "FAIL"; exit 1
else echo "INCONCLUSIVE"; exit 2; fi
