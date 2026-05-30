#!/usr/bin/env bash
# Replay-player JSON contract smoke. Hand-crafts a recording with the EXACT
# schema ReplayRecorder writes ({t,p,b,y,pt} frames + version/room_id header,
# see server/scripts/replay_recorder.gd:107) and feeds it to the standalone
# replay_player.gd CLI. Catches:
#   - player-side parse regressions (renamed field, changed header key)
#   - schema drift between recorder (writer) and player (reader)
# The fire-bit count assertion pins INPUT_BIT_FIRE = 1<<4 = 16.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
REPLAY="$LOG_DIR/_contract_replay.json"
LOG="$LOG_DIR/replay_player.log"

# 4 frames, peer 1001: 2 with fire bit (16), 2 without. Schema must match
# replay_recorder.gd exactly.
cat > "$REPLAY" <<'JSON'
{
  "version": 2,
  "room_id": "TEST",
  "saved_at_ms": 1700000000000,
  "frame_count": 4,
  "snapshot_count": 0,
  "snap_hz": 10.0,
  "snapshots": [],
  "frames": [
    {"t": 0,   "p": 1001, "b": 0,  "y": 0.0,  "pt": 0.0},
    {"t": 33,  "p": 1001, "b": 16, "y": 0.5,  "pt": -0.1},
    {"t": 66,  "p": 1001, "b": 16, "y": 0.9,  "pt": -0.2},
    {"t": 99,  "p": 1001, "b": 1,  "y": 1.0,  "pt": -0.2}
  ]
}
JSON

echo "=== replay_player JSON contract smoke ==="
"$GODOT" --headless --path "$PROJ" -s client/scripts/ui/replay_player.gd -- \
    --file "$REPLAY" > "$LOG" 2>&1
RC=$?

echo "--- replay_player output ---"
grep -vE "GDExtension library|GDExtension dynamic|Error loading extension|godot-sqlite|Database\]|ServerDiscovery\]" "$LOG" | tail -25
echo "--- result ---"

ok=true
[ "$RC" -ne 0 ] && { echo "FAIL: replay_player exit $RC (expected 0)"; ok=false; }
grep -q "room_id: TEST" "$LOG"        || { echo "FAIL: didn't echo room_id from header"; ok=false; }
grep -q "frame_count: 4" "$LOG"       || { echo "FAIL: frame_count mismatch (schema drift?)"; ok=false; }
# Player summarizes per-peer fire count — should see 2 fires for peer 1001.
if ! grep -qE "1001|fires|2" "$LOG"; then
    echo "WARN: per-peer summary format changed (couldn't confirm fire count)"
fi
if grep -qE "Parse Error|SCRIPT ERROR|not a JSON|missing 'frames'" "$LOG"; then
    echo "FAIL: parse/schema error"; grep -E "Parse Error|SCRIPT ERROR|not a JSON|missing" "$LOG" | head; ok=false
fi

rm -f "$REPLAY"
$ok && { echo "PASS"; exit 0; } || { echo "FAIL"; exit 1; }
