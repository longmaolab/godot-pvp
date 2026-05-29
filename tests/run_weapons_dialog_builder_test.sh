#!/usr/bin/env bash
# Unit test for WeaponsDialogBuilder — the weapon-catalog card renderer
# extracted from main_menu.gd (P1-14 god-object split).
# See tests/weapons_dialog_builder_test.gd for the assertions.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/weapons_dialog_builder.log"

echo "=== WeaponsDialogBuilder unit test ==="
"$GODOT" --headless --path "$PROJ" -s tests/weapons_dialog_builder_test.gd \
	>"$LOG" 2>&1 &
PID=$!
( sleep 30 && kill -9 $PID 2>/dev/null && echo "[killed after 30s]" >>"$LOG" ) &
KILLER=$!
wait $PID 2>/dev/null
kill "$KILLER" 2>/dev/null

echo "--- log tail ---"
grep -ivE "NetProtocol|proc_audio|server_discovery|persistence/settings|stats_store|replay_recorder|godot-sqlite" "$LOG" | tail -10
echo "--- result ---"
if grep -q "^  PASS — " "$LOG"; then
	echo "PASS"
	exit 0
else
	echo "FAIL"
	exit 1
fi
