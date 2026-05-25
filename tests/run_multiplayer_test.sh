#!/usr/bin/env bash
# Integration test: spawn headless server, connect headless client, check that
# the client receives server_welcome RPC and both shut down cleanly.

set -u

GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
SERVER_LOG="$LOG_DIR/server.log"
CLIENT_LOG="$LOG_DIR/client.log"

echo "=== multiplayer integration test ==="
echo "godot: $GODOT"
echo "logs:  $LOG_DIR"

# 1) Start server in background, auto-exit after 12s so it doesn't linger if
#    the client test crashes.
"$GODOT" --headless --path "$PROJ" -- --server --port 7777 --seconds 12 \
    >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
echo "server pid=$SERVER_PID, waiting 2s for boot..."
sleep 2

# 2) Run client; it self-quits when welcome received (exit 0) or on timeout (exit 1).
"$GODOT" --headless --path "$PROJ" tests/headless_client.tscn \
    -- --address ws://127.0.0.1:7777 \
    >"$CLIENT_LOG" 2>&1
CLIENT_RC=$?

# 3) Bring the server down (kill, then wait — it self-exits at 12s anyway).
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

echo "--- server log ---"
cat "$SERVER_LOG"
echo "--- client log ---"
cat "$CLIENT_LOG"
echo "--- result ---"

if [ "$CLIENT_RC" -ne 0 ]; then
    echo "FAIL — client exit code $CLIENT_RC"
    exit 1
fi
if ! grep -q "PASS" "$CLIENT_LOG"; then
    echo "FAIL — client did not print PASS"
    exit 1
fi
if ! grep -qE "peer connected|spawned player for peer" "$SERVER_LOG"; then
    echo "FAIL — server never logged peer connect / spawn"
    exit 1
fi
if ! grep -q "hello from" "$SERVER_LOG"; then
    echo "FAIL — server never logged client_hello"
    exit 1
fi

echo "PASS"
exit 0
