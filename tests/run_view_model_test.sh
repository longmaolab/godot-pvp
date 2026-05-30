#!/usr/bin/env bash
set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$PROJ/tests/.logs/view_model.log"; mkdir -p "$PROJ/tests/.logs"
"$GODOT" --headless --path "$PROJ" -s tests/view_model_test.gd >"$LOG" 2>&1 &
PID=$!; ( sleep 30 && kill -9 $PID 2>/dev/null ) & K=$!; wait $PID 2>/dev/null; kill $K 2>/dev/null
tail -8 "$LOG"
grep -q "VIEWMODEL PASS" "$LOG" && { echo PASS; exit 0; } || { echo FAIL; exit 1; }
