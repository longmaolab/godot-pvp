#!/usr/bin/env bash
# Reconnect regression: client connects to DS, gets spawned, disconnects,
# reconnects in the same process. The "first client → Esc → Main Menu →
# JOIN again" flow the user is hitting.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
PORT=9202
SERVER_LOG="$LOG_DIR/rejoin_server.log"
CLIENT_LOG="$LOG_DIR/rejoin_client.log"

echo "=== DS rejoin test ==="
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 12 \
	>"$SERVER_LOG" 2>&1 &
SPID=$!
sleep 1.2

"$GODOT" --headless --path "$PROJ" tests/headless_rejoin_client.tscn \
	-- --address "ws://127.0.0.1:$PORT" \
	>"$CLIENT_LOG" 2>&1 &
CPID=$!

wait $CPID
RC=$?
wait $SPID

echo "--- server log (tail) ---"
tail -25 "$SERVER_LOG"
echo "--- client log (tail) ---"
tail -25 "$CLIENT_LOG"

ok=true
if [[ $RC -ne 0 ]]; then
	echo "FAIL: rejoin client exited $RC"
	ok=false
fi
# Server should report 2 spawns + 1 despawn (between).
spawns=$(grep -c "spawned player for peer" "$SERVER_LOG" 2>/dev/null || true)
spawns=${spawns:-0}
despawns=$(grep -c "despawned peer" "$SERVER_LOG" 2>/dev/null || true)
despawns=${despawns:-0}
echo "server: $spawns spawns, $despawns despawns"
if (( spawns < 2 )); then
	echo "FAIL: only $spawns spawns (expected 2 — second join didn't reach server)"
	ok=false
fi

if $ok; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
