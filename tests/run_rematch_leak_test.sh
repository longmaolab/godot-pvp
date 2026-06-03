#!/usr/bin/env bash
# Reproduction harness + regression guard for the "two clients crash
# simultaneously after a few matches" report. Boots a room match, ends it
# (real _tear_down_match_world teardown), rematches CYCLES times, and asserts
# the server's live node count doesn't climb across rematches (a leak there
# would accumulate on every client until the GPU/renderer crashes). Also scans
# every entity for NaN/Inf positions (the other GPU-crash vector).
set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/rematch_leak.log"
echo "=== rematch leak / NaN reproduction harness ==="
"$GODOT" --headless --path "$PROJ" -s tests/rematch_leak_test.gd >"$LOG" 2>&1 &
PID=$!; ( sleep 40 && kill -9 $PID 2>/dev/null && echo "[killed]" >>"$LOG" ) & K=$!; wait $PID 2>/dev/null; kill "$K" 2>/dev/null
echo "--- log (rematch-leak lines) ---"; grep -E "rematch-leak|ok\]|PASS|FAIL" "$LOG" | tail -16
if grep -q "^  PASS — " "$LOG"; then echo "PASS"; exit 0
elif grep -q "^  FAIL" "$LOG"; then echo "FAIL"; exit 1
else echo "INCONCLUSIVE"; exit 2; fi
