#!/usr/bin/env bash
# Regression guard: character GLBs get the 180° facing correction (Kenney
# models face +Z; node forward is -Z). Without it, opponents see each other's
# back and moving characters run backwards.
set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/skin_facing.log"
echo "=== character facing (180° GLB correction) test ==="
"$GODOT" --headless --path "$PROJ" -s tests/skin_facing_test.gd >"$LOG" 2>&1 &
PID=$!; ( sleep 30 && kill -9 $PID 2>/dev/null && echo "[killed]" >>"$LOG" ) & K=$!; wait $PID 2>/dev/null; kill "$K" 2>/dev/null
echo "--- log tail ---"; grep -E "ok\]|PASS|FAIL" "$LOG" | tail -6
if grep -q "^  PASS — " "$LOG"; then echo "PASS"; exit 0
elif grep -q "^  FAIL:" "$LOG"; then echo "FAIL"; exit 1
else echo "INCONCLUSIVE"; exit 2; fi
