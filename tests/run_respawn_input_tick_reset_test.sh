#!/usr/bin/env bash
# Regression: respawn() resets _remote_input_tick so post-rematch input
# from a fresh client (ticks restarting at 1) isn't rejected by the
# replay-protection guard. See tests/respawn_input_tick_reset_test.gd.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/respawn_input_tick_reset.log"

echo "=== respawn input-tick reset test ==="
"$GODOT" --headless --path "$PROJ" -s tests/respawn_input_tick_reset_test.gd \
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
