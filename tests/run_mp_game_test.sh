#!/usr/bin/env bash
# Spawn two Godot processes (host + client) that both load game.tscn over WebSocket,
# wait for spawn RPCs to flow, and assert each side has 2 players in its scene.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
HOST_LOG="$LOG_DIR/mp_host.log"
CLIENT_LOG="$LOG_DIR/mp_client.log"
PORT=9108   # was 7778 — moved to free 7778 for DS default port

echo "=== multiplayer game-spawn integration test ==="

# Host (listen server). Both spawns happen on host side once client connects.
"$GODOT" --headless --path "$PROJ" tests/mp_game_test.tscn \
    -- --role host --port "$PORT" --wait 5 \
    >"$HOST_LOG" 2>&1 &
HOST_PID=$!
echo "host pid=$HOST_PID; waiting 1.5s for boot..."
sleep 1.5

# Client.
"$GODOT" --headless --path "$PROJ" tests/mp_game_test.tscn \
    -- --role client --address "ws://127.0.0.1:$PORT" --wait 4 \
    >"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

# Wait for both.
wait "$HOST_PID"
HOST_RC=$?
wait "$CLIENT_PID"
CLIENT_RC=$?

echo "--- host log (rc=$HOST_RC) ---"
cat "$HOST_LOG"
echo "--- client log (rc=$CLIENT_RC) ---"
cat "$CLIENT_LOG"
echo "--- result ---"

ok=true
if [ "$HOST_RC" -ne 0 ]; then echo "host exit code: $HOST_RC (want 0)"; ok=false; fi
if [ "$CLIENT_RC" -ne 0 ]; then echo "client exit code: $CLIENT_RC (want 0)"; ok=false; fi
if ! grep -q "host\] PASS" "$HOST_LOG"; then echo "host did not log PASS"; ok=false; fi
if ! grep -q "client\] PASS" "$CLIENT_LOG"; then echo "client did not log PASS"; ok=false; fi

if $ok; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
