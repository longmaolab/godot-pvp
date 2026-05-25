#!/usr/bin/env bash
# DS-M1 verification: boots a real dedicated server (--server) and a headless
# client that connects to it. Asserts the server logged:
#   1. "[server] ready — world mounted, awaiting peers"
#   2. "[server] spawned player for peer N"     ← the client triggered a spawn
# Both processes self-terminate via --seconds.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
SERVER_LOG="$LOG_DIR/server_boot_server.log"
CLIENT_LOG="$LOG_DIR/server_boot_client.log"
PORT=9101

echo "=== DS-M1 server-boot test ==="
echo "[host] starting godot --server on :$PORT"
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 6 \
	>"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Give the server a beat to bind the port.
sleep 1.2

echo "[host] starting headless_client.tscn → ws://127.0.0.1:$PORT"
"$GODOT" --headless --path "$PROJ" \
	tests/headless_client.tscn -- --address "ws://127.0.0.1:$PORT" \
	>"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

wait $SERVER_PID
SERVER_RC=$?
wait $CLIENT_PID
CLIENT_RC=$?

echo "--- server log (last 25 lines) ---"
tail -25 "$SERVER_LOG"
echo "--- client log (last 15 lines) ---"
tail -15 "$CLIENT_LOG"

ok=true
if ! grep -q "\[server\] ready — world mounted, awaiting peers" "$SERVER_LOG"; then
	echo "FAIL — server never logged 'world mounted'"; ok=false
fi
if ! grep -qE "\[server\] spawned player for peer [0-9]+" "$SERVER_LOG"; then
	echo "FAIL — server never spawned a player for the connecting client"; ok=false
fi
if grep -qE "ERROR:|Parse Error|SCRIPT ERROR" "$SERVER_LOG"; then
	echo "FAIL — server logged hard errors:"
	grep -E "ERROR:|Parse Error|SCRIPT ERROR" "$SERVER_LOG" | head -10
	ok=false
fi
if grep -qE "ERROR:|Parse Error|SCRIPT ERROR" "$CLIENT_LOG"; then
	echo "WARN — client logged errors:"
	grep -E "ERROR:|Parse Error|SCRIPT ERROR" "$CLIENT_LOG" | head -10
fi

if $ok; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
