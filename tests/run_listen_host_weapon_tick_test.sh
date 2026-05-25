#!/usr/bin/env bash
# Regression test: listen-host server-side view of remote players must tick
# weapon cooldown + reload timer. See tests/listen_host_weapon_tick_test.gd
# for the bug background.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/listen_host_weapon_tick.log"

echo "=== listen-host weapon tick test ==="
"$GODOT" --headless --path "$PROJ" -s tests/listen_host_weapon_tick_test.gd \
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
	echo "INCONCLUSIVE (no PASS/FAIL marker in log)"
	exit 2
fi
