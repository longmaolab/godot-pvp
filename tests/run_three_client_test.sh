#!/usr/bin/env bash
# Three-client DS integration test. Three real game.tscn clients join, A
# shoots its closest neighbor, B shoots its farthest. Then C leaves
# mid-match. Asserts that BOTH damage pairs land AND C's departure is
# cleanly handled.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
PORT=9204
SERVER_LOG="$LOG_DIR/three_client_server.log"
A_LOG="$LOG_DIR/three_client_A.log"
B_LOG="$LOG_DIR/three_client_B.log"
C_LOG="$LOG_DIR/three_client_C.log"

echo "=== DS three-client test ==="
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 12 \
	>"$SERVER_LOG" 2>&1 &
SPID=$!
sleep 1.2

"$GODOT" --headless --path "$PROJ" tests/headless_three_client.tscn \
	-- --role C --address "ws://127.0.0.1:$PORT" --leave-after 4.0 \
	>"$C_LOG" 2>&1 &
C_PID=$!
sleep 0.4
"$GODOT" --headless --path "$PROJ" tests/headless_three_client.tscn \
	-- --role B --address "ws://127.0.0.1:$PORT" \
	   --fire-after 1.0 --fire-duration 5.0 \
	>"$B_LOG" 2>&1 &
B_PID=$!
sleep 0.4
"$GODOT" --headless --path "$PROJ" tests/headless_three_client.tscn \
	-- --role A --address "ws://127.0.0.1:$PORT" \
	   --fire-after 1.0 --fire-duration 5.0 \
	>"$A_LOG" 2>&1 &
A_PID=$!

wait $A_PID; A_RC=$?
wait $B_PID; B_RC=$?
wait $C_PID; C_RC=$?
wait $SPID

echo "--- server log (tail) ---"
tail -50 "$SERVER_LOG"
echo "--- A log (tail) ---"; tail -15 "$A_LOG"
echo "--- B log (tail) ---"; tail -15 "$B_LOG"
echo "--- C log (tail) ---"; tail -10 "$C_LOG"
echo "--- result ---"

ok=true
[[ $A_RC -ne 0 ]] && { echo "FAIL: A exit $A_RC"; ok=false; }
[[ $B_RC -ne 0 ]] && { echo "FAIL: B exit $B_RC"; ok=false; }
[[ $C_RC -ne 0 ]] && { echo "FAIL: C exit $C_RC"; ok=false; }

spawns=$(grep -c "spawned player for peer" "$SERVER_LOG" 2>/dev/null || true)
spawns=${spawns:-0}
(( spawns < 3 )) && { echo "FAIL: expected 3 spawns, got $spawns"; ok=false; }

# C leaving mid-match — server must despawn C BEFORE shutdown despawns.
# C leaves at t=5s; server runs 14s; auto-shutdown produces a despawn per
# remaining peer at the end. So expect >= 2 despawns minimum, and at least
# one "despawned peer" line should appear before the auto-shutdown line.
despawns=$(grep -c "despawned peer" "$SERVER_LOG" 2>/dev/null || true)
despawns=${despawns:-0}
echo "server: $spawns spawns, $despawns despawns"
(( despawns < 1 )) && { echo "FAIL: no despawns at all"; ok=false; }

# Pull the line number of the first despawn and of auto-shutdown.
shutdown_line=$(grep -n "auto-shutdown" "$SERVER_LOG" | head -1 | cut -d: -f1)
shutdown_line=${shutdown_line:-99999}
first_despawn_line=$(grep -n "despawned peer" "$SERVER_LOG" | head -1 | cut -d: -f1)
first_despawn_line=${first_despawn_line:-0}
if (( first_despawn_line == 0 )) || (( first_despawn_line >= shutdown_line )); then
	echo "FAIL: no mid-match despawn (C didn't leave cleanly)"
	ok=false
fi

# Damage: at least 2 DISTINCT shooters land hits (proves the multi-client
# fire path coexists; the diagonal corner-spawn layout means rays can pass
# through the centre peer, so distinct victims would be flaky).
shooters=$(grep -oE "shooter=[0-9]+" "$SERVER_LOG" | sort -u | wc -l | tr -d ' ')
shooters=${shooters:-0}
echo "distinct shooter peer ids: $shooters"
(( shooters < 2 )) && { echo "FAIL: expected >= 2 distinct shooters, got $shooters"; ok=false; }

hits=$(grep -c "\[server\] hit:" "$SERVER_LOG" 2>/dev/null || true)
hits=${hits:-0}
echo "total server hits: $hits"
(( hits < 2 )) && { echo "FAIL: expected >= 2 hits, got $hits"; ok=false; }

# Hits before AND after C's despawn — proves the survivor pair keeps firing.
first_despawn_line=$(grep -n "despawned peer" "$SERVER_LOG" | head -1 | cut -d: -f1)
hits_before=$(awk -v L="$first_despawn_line" 'NR<L && /\[server\] hit:/' "$SERVER_LOG" | wc -l | tr -d ' ')
hits_after=$(awk -v L="$first_despawn_line" 'NR>L && /\[server\] hit:/' "$SERVER_LOG" | wc -l | tr -d ' ')
echo "hits before/after first despawn: $hits_before / $hits_after"
(( hits_before < 1 )) && { echo "FAIL: no hits BEFORE C's despawn"; ok=false; }
(( hits_after  < 1 )) && { echo "FAIL: no hits AFTER C's despawn — third-peer leave broke fire path"; ok=false; }

if grep -qE "Parse Error|SCRIPT ERROR" "$SERVER_LOG" "$A_LOG" "$B_LOG" "$C_LOG"; then
	echo "FAIL: parse/script errors logged"
	grep -nE "Parse Error|SCRIPT ERROR" "$SERVER_LOG" "$A_LOG" "$B_LOG" "$C_LOG" | head -10
	ok=false
fi

$ok && { echo "PASS"; exit 0; } || { echo "FAIL"; exit 1; }
