#!/usr/bin/env bash
# Unit test for throwable AoE math (server-only).
set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/grenade.log"

echo "=== throwable / grenade AoE test ==="
"$GODOT" --headless --path "$PROJ" -s tests/grenade_test.gd >"$LOG" 2>&1 &
PID=$!
( sleep 30 && kill -9 $PID 2>/dev/null && echo "[killed after 30s]" >>"$LOG" ) &
KILLER=$!
wait $PID 2>/dev/null
kill "$KILLER" 2>/dev/null

echo "--- log tail ---"
tail -20 "$LOG"
echo "--- result ---"

if grep -q "^  PASS — " "$LOG"; then
    echo "PASS"
    exit 0
elif grep -q "^  FAIL:" "$LOG"; then
    echo "FAIL"
    exit 1
else
    echo "INCONCLUSIVE"
    exit 2
fi
