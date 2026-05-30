#!/usr/bin/env bash
set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/melee.log"
echo "=== melee test ==="
"$GODOT" --headless --path "$PROJ" -s tests/melee_test.gd >"$LOG" 2>&1 &
PID=$!; ( sleep 30 && kill -9 $PID 2>/dev/null && echo "[killed]" >>"$LOG" ) & K=$!; wait $PID 2>/dev/null; kill "$K" 2>/dev/null
echo "--- log tail ---"; tail -10 "$LOG"
if grep -q "^  PASS — " "$LOG"; then echo "PASS"; exit 0
elif grep -q "^  FAIL — " "$LOG"; then echo "FAIL"; exit 1
else echo "INCONCLUSIVE"; exit 2; fi
