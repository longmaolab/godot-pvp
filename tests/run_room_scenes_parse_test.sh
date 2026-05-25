#!/usr/bin/env bash
# Scene-parse smoke test for room_browser.tscn + room_lobby.tscn.
set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/room_scenes_parse.log"

echo "=== room scenes parse smoke ==="
"$GODOT" --headless --path "$PROJ" -s tests/room_scenes_parse_test.gd \
	>"$LOG" 2>&1 &
PID=$!
( sleep 30 && kill -9 $PID 2>/dev/null && echo "[killed after 30s]" >>"$LOG" ) &
KILLER=$!
wait $PID 2>/dev/null
kill "$KILLER" 2>/dev/null

echo "--- log tail ---"
tail -15 "$LOG"
echo "--- result ---"

if grep -q "^  PASS — " "$LOG"; then
	echo "PASS"; exit 0
elif grep -q "^  FAIL — " "$LOG"; then
	echo "FAIL"; exit 1
else
	echo "INCONCLUSIVE"; exit 2
fi
