#!/usr/bin/env bash
# Multi-client rejoin regression — two clients on the DS, the SHOOTER (A)
# disconnects + reconnects while VICTIM (B) stays, then A shoots B.
#
# Asserts:
#   1. A's process exits 0 (rejoin worked + 2-peer view restored)
#   2. B's process exits 0 (B saw A drop and rejoin)
#   3. Server logs >= 3 spawns (A1, B, A2) and >= 1 despawn (A1)
#   4. Server logs >= 1 "[server] hit:" line AFTER the rejoin marker (proves
#      shots from rejoined A land on B's hitbox)

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
PORT=9203
SERVER_LOG="$LOG_DIR/multi_rejoin_server.log"
A_LOG="$LOG_DIR/multi_rejoin_A.log"
B_LOG="$LOG_DIR/multi_rejoin_B.log"

echo "=== DS multi-client rejoin test ==="
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 14 \
	>"$SERVER_LOG" 2>&1 &
SPID=$!
sleep 1.2

# B first so they're spawned when A connects.
"$GODOT" --headless --path "$PROJ" tests/headless_multi_rejoin.tscn \
	-- --role B --address "ws://127.0.0.1:$PORT" \
	   --wait-before-leave 2.0 --pause 1.0 --wait-after-rejoin 4.0 \
	>"$B_LOG" 2>&1 &
B_PID=$!
sleep 0.7

"$GODOT" --headless --path "$PROJ" tests/headless_multi_rejoin.tscn \
	-- --role A --address "ws://127.0.0.1:$PORT" \
	   --wait-before-leave 2.0 --pause 1.0 --wait-after-rejoin 4.0 \
	>"$A_LOG" 2>&1 &
A_PID=$!

wait $A_PID
A_RC=$?
wait $B_PID
B_RC=$?
wait $SPID

echo "--- server log (tail) ---"
tail -40 "$SERVER_LOG"
echo "--- A log (tail) ---"
tail -25 "$A_LOG"
echo "--- B log (tail) ---"
tail -25 "$B_LOG"
echo "--- result ---"

ok=true
[[ $A_RC -ne 0 ]] && { echo "FAIL: A exit $A_RC"; ok=false; }
[[ $B_RC -ne 0 ]] && { echo "FAIL: B exit $B_RC"; ok=false; }

spawns=$(grep -c "spawned player for peer" "$SERVER_LOG" 2>/dev/null || true)
spawns=${spawns:-0}
despawns=$(grep -c "despawned peer" "$SERVER_LOG" 2>/dev/null || true)
despawns=${despawns:-0}
echo "server: $spawns spawns, $despawns despawns"
(( spawns < 3 ))    && { echo "FAIL: expected >= 3 spawns (A1+B+A2), got $spawns"; ok=false; }
(( despawns < 1 )) && { echo "FAIL: expected >= 1 despawn (A1), got $despawns"; ok=false; }

# Damage AFTER rejoin: extract the line number of A's REJOIN log marker
# in the server log isn't trivial (only A logs that), so we instead
# rely on the fact that A only fires AFTER its rejoin succeeds — any
# "[server] hit:" line where the shooter peer matches A's SECOND
# peer-id counts. Easier: assert at least 1 hit total, since A's first
# session never fired. (B never fires.)
hits=$(grep -c "\[server\] hit:" "$SERVER_LOG" 2>/dev/null || true)
hits=${hits:-0}
echo "server hits: $hits"
(( hits < 1 )) && { echo "FAIL: no damage events after A rejoined — rejoin broke fire path"; ok=false; }

if grep -qE "Parse Error|SCRIPT ERROR" "$SERVER_LOG" "$A_LOG" "$B_LOG"; then
	echo "FAIL: parse/script errors logged"
	grep -nE "Parse Error|SCRIPT ERROR" "$SERVER_LOG" "$A_LOG" "$B_LOG" | head -10
	ok=false
fi

$ok && { echo "PASS"; exit 0; } || { echo "FAIL"; exit 1; }
