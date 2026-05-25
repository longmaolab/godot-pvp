#!/usr/bin/env bash
# Player-vs-player collision regression test (Jolt physics).
# See tests/player_collision_test.gd for what it checks.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/player_collision.log"

echo "=== player-vs-player collision test ==="
"$GODOT" --headless --path "$PROJ" -s tests/player_collision_test.gd \
	>"$LOG" 2>&1 &
PID=$!
( sleep 30 && kill -9 $PID 2>/dev/null && echo "[killed after 30s]" >>"$LOG" ) &
KILLER=$!
wait $PID 2>/dev/null
kill "$KILLER" 2>/dev/null

echo "--- log tail ---"
tail -30 "$LOG"
echo "--- result ---"

if grep -q "^  PASS — " "$LOG"; then
	echo "PASS"
	exit 0
elif grep -q "^  FAIL — " "$LOG"; then
	echo "FAIL"
	exit 1
else
	echo "INCONCLUSIVE (no PASS/FAIL marker)"
	exit 2
fi
