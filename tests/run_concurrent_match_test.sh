#!/usr/bin/env bash
# Integration test for F3-M5: concurrent matches in two rooms isolated.
# See tests/concurrent_match_test.gd for the assertions.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/concurrent_match.log"

echo "=== Concurrent-match isolation test ==="
"$GODOT" --headless --path "$PROJ" -s tests/concurrent_match_test.gd \
	>"$LOG" 2>&1 &
PID=$!
( sleep 30 && kill -9 $PID 2>/dev/null && echo "[killed after 30s]" >>"$LOG" ) &
KILLER=$!
wait $PID 2>/dev/null
kill "$KILLER" 2>/dev/null

echo "--- log tail ---"
tail -40 "$LOG"
echo "--- result ---"

if grep -q "^  PASS — " "$LOG"; then
	echo "PASS"
	exit 0
elif grep -q "^  FAIL: " "$LOG"; then
	echo "FAIL"
	exit 1
else
	echo "INCONCLUSIVE (no PASS/FAIL marker)"
	exit 2
fi
