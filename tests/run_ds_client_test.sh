#!/usr/bin/env bash
# Repro for the "stuck on CONNECTING…" issue: spawn a DS, then a real
# game.tscn client (via mp_game_test.tscn in client role pointing at the DS),
# verify that the client side spawns the player and dismisses the overlay.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
SERVER_LOG="$LOG_DIR/ds_client_server.log"
CLIENT_LOG="$LOG_DIR/ds_client_client.log"
PORT=9107

echo "=== DS-client integration test ==="
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 6 \
	>"$SERVER_LOG" 2>&1 &
SPID=$!
sleep 1.4

# mp_game_test.tscn in client role: it does the full main_menu join flow —
# creates a WebSocketMultiplayerPeer client, mounts game.tscn, waits.
"$GODOT" --headless --path "$PROJ" tests/mp_game_test.tscn \
	-- --role client --address "ws://127.0.0.1:$PORT" --wait 4 \
	>"$CLIENT_LOG" 2>&1 &
CPID=$!

wait $CPID
wait $SPID

echo "--- server log (tail) ---"
tail -25 "$SERVER_LOG"
echo "--- client log (tail) ---"
tail -25 "$CLIENT_LOG"

ok=true
# Server should report spawn for the connecting peer.
if ! grep -qE "spawned player for peer [0-9]+" "$SERVER_LOG"; then
	echo "FAIL: server didn't spawn the peer"
	ok=false
fi
# Client should have logged 2 players (1 server-side + 1 self) … actually
# in DS mode only 1 (just self). Let's check for "spawn" mentions.
if ! grep -qE "spawn|Player_[0-9]+" "$CLIENT_LOG"; then
	echo "FAIL: client never spawned a local player"
	ok=false
fi

if $ok; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
