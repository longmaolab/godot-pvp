#!/usr/bin/env bash
# Verify listen-host accepts multiple shots from a remote client, not just the
# first one in the burst.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
HOST_LOG="$LOG_DIR/mp_burst_host.log"
CLIENT_LOG="$LOG_DIR/mp_burst_client.log"
PORT=9219

echo "=== listen-host burst damage regression test ==="

"$GODOT" --headless --path "$PROJ" tests/mp_burst_hit_test.tscn \
	-- --role host --port "$PORT" >"$HOST_LOG" 2>&1 &
HOST_PID=$!
sleep 1.5

"$GODOT" --headless --path "$PROJ" tests/mp_burst_hit_test.tscn \
	-- --role client --address "ws://127.0.0.1:$PORT" >"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

wait "$HOST_PID"
HOST_RC=$?
wait "$CLIENT_PID"
CLIENT_RC=$?

echo "--- host log (rc=$HOST_RC) ---"
grep -E "^\[" "$HOST_LOG" | tail -30
echo "--- client log (rc=$CLIENT_RC) ---"
grep -E "^\[" "$CLIENT_LOG" | tail -30
echo "--- result ---"

ok=true
[ "$HOST_RC" -ne 0 ] && { echo "host exit=$HOST_RC"; ok=false; }
[ "$CLIENT_RC" -ne 0 ] && { echo "client exit=$CLIENT_RC"; ok=false; }
grep -q "host\] PASS" "$HOST_LOG" || { echo "host did not log PASS"; ok=false; }
grep -q "client\] PASS" "$CLIENT_LOG" || { echo "client did not log PASS"; ok=false; }

$ok && { echo "PASS"; exit 0; } || { echo "FAIL"; exit 1; }
