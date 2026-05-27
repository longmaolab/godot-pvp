#!/usr/bin/env bash
# Rigorous match-end / rematch flow test. Covers RoomManager start_match
# host gate + MatchEnd UI's reaction to server reject feedback.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/rematch_reject.log"

echo "=== rematch reject test ==="
"$GODOT" --headless --path "$PROJ" -s tests/rematch_reject_test.gd \
	>"$LOG" 2>&1 &
PID=$!
( sleep 30 && kill -9 $PID 2>/dev/null && echo "[killed after 30s]" >>"$LOG" ) &
KILLER=$!
wait $PID 2>/dev/null
kill "$KILLER" 2>/dev/null

echo "--- log tail ---"
tail -20 "$LOG"
echo "--- result ---"

if grep -q "PASS — " "$LOG"; then
	echo "PASS"
	exit 0
elif grep -q "FAIL — " "$LOG"; then
	echo "FAIL"
	exit 1
else
	echo "INCONCLUSIVE (no PASS/FAIL marker)"
	exit 2
fi
