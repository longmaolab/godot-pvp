#!/usr/bin/env bash
# Geometry regression test: verifies that the player HeadHitbox / BodyHitbox
# actually cover the visible character model. Catches the class of bug
# where someone scales the GLB skin (or moves a hitbox) without thinking
# about the other side, and rays start passing through air at chest height.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/hitbox_geometry.log"

echo "=== hitbox geometry test ==="
"$GODOT" --headless --path "$PROJ" -s tests/hitbox_geometry_test.gd \
	>"$LOG" 2>&1 &
PID=$!
( sleep 45 && kill -9 $PID 2>/dev/null && echo "[killed after 45s]" >>"$LOG" ) &
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
