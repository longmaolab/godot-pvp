#!/usr/bin/env bash
# DS-M5 verification: client connects to DS. After 1.5s the server-side
# helper kills the player (apply_damage 9999). 3s later the server schedules
# a respawn + broadcasts server_player_respawned. Client logs the RPC.
#
# Asserts on server log:
#   "peer N died — respawning in 3s"
#   "peer N respawned at (...)"
# Asserts on client log:
#   "server_player_respawned: peer=N at (...)"

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
PORT=9106
SERVER_LOG="$LOG_DIR/respawn_server.log"
CLIENT_LOG="$LOG_DIR/respawn_client.log"

echo "=== DS-M5 respawn test ==="
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 8 --test-kill-after 1.5 \
	>"$SERVER_LOG" 2>&1 &
SPID=$!
sleep 1.2

# Client runs for ~6s so it observes both death + respawn (3s respawn delay).
"$GODOT" --headless --path "$PROJ" \
	tests/headless_input_client.tscn -- \
	--address "ws://127.0.0.1:$PORT" --duration 6.0 --bits 0 \
	>"$CLIENT_LOG" 2>&1 &
CPID=$!

wait $CPID
wait $SPID

echo "--- server log (tail) ---"
tail -25 "$SERVER_LOG"
echo "--- client log (tail) ---"
tail -25 "$CLIENT_LOG"

ok=true
if ! grep -qE "peer [0-9]+ died — respawning in 3s" "$SERVER_LOG"; then
	echo "FAIL: server never logged death"
	ok=false
fi
if ! grep -qE "peer [0-9]+ respawned at" "$SERVER_LOG"; then
	echo "FAIL: server never logged respawn"
	ok=false
fi
if ! grep -qE "server_player_respawned: peer=[0-9]+" "$CLIENT_LOG"; then
	echo "FAIL: client never received server_player_respawned RPC"
	ok=false
fi
# After respawn the client's snapshot self.hp should be back at full (300).
# (The test-kill-after path doesn't use server_apply_damage — that's only for
# fire-resolved damage. HP propagates via snapshot.)
final_hp=$(grep -oE "last snapshot self hp: [0-9]+" "$CLIENT_LOG" | grep -oE "[0-9]+$" || echo "0")
echo "client final hp from snapshot: $final_hp"
if (( final_hp < 250 )); then
	echo "FAIL: client's final HP from snapshot is $final_hp (expected ~300 after respawn)"
	ok=false
fi
if grep -qE "ERROR:|Parse Error|SCRIPT ERROR" "$SERVER_LOG"; then
	echo "FAIL: server logged errors"
	grep -E "ERROR:|Parse Error|SCRIPT ERROR" "$SERVER_LOG" | head -5
	ok=false
fi

if $ok; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
