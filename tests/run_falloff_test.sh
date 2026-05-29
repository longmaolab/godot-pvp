#!/usr/bin/env bash
set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/falloff.log"
echo "=== damage falloff test ==="
"$GODOT" --headless --path "$PROJ" -s tests/falloff_test.gd >"$LOG" 2>&1 &
PID=$!; ( sleep 20 && kill -9 $PID 2>/dev/null ) & K=$!; wait $PID 2>/dev/null; kill "$K" 2>/dev/null
tail -6 "$LOG"
if grep -q "^  PASS — " "$LOG"; then echo "PASS"; exit 0
elif grep -q "^  FAIL — " "$LOG"; then echo "FAIL"; exit 1
else echo "INCONCLUSIVE"; exit 2; fi
