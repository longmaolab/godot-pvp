#!/usr/bin/env bash
# Real-camera-aim hit test. Uses player_controller.try_fire() (the real LMB
# path) instead of bypassing it with manual client_fire RPCs. Catches
# mismatches between the client's camera/aim state and what the server
# raycasts against.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
PORT=9205
SERVER_LOG="$LOG_DIR/real_aim_server.log"
A_LOG="$LOG_DIR/real_aim_A.log"
B_LOG="$LOG_DIR/real_aim_B.log"

echo "=== DS real-camera-aim test ==="
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 8 \
	>"$SERVER_LOG" 2>&1 &
SPID=$!
sleep 1.2

"$GODOT" --headless --path "$PROJ" tests/headless_real_aim.tscn \
	-- --role B --address "ws://127.0.0.1:$PORT" --wait 5.0 \
	>"$B_LOG" 2>&1 &
B_PID=$!
sleep 0.7
"$GODOT" --headless --path "$PROJ" tests/headless_real_aim.tscn \
	-- --role A --address "ws://127.0.0.1:$PORT" --wait 4.0 \
	>"$A_LOG" 2>&1 &
A_PID=$!

wait $A_PID; A_RC=$?
wait $B_PID; B_RC=$?
wait $SPID

echo "--- server log (tail) ---"; tail -30 "$SERVER_LOG"
echo "--- A log (tail) ---"; tail -15 "$A_LOG"
echo "--- B log (tail) ---"; tail -15 "$B_LOG"
echo "--- result ---"

ok=true
[[ $A_RC -ne 0 ]] && { echo "FAIL: A exit $A_RC"; ok=false; }
[[ $B_RC -ne 0 ]] && { echo "FAIL: B exit $B_RC"; ok=false; }

spawns=$(grep -c "spawned player for peer" "$SERVER_LOG" 2>/dev/null || true)
spawns=${spawns:-0}
(( spawns < 2 )) && { echo "FAIL: expected >= 2 spawns, got $spawns"; ok=false; }

hits=$(grep -c "\[server\] hit:" "$SERVER_LOG" 2>/dev/null || true)
hits=${hits:-0}
echo "server hits: $hits"
# Aim drives the real camera basis on the client; server must register
# >= 3 hits over a 4s burst, otherwise either the aim isn't propagating
# through `_aim_yaw`/`_aim_pitch` → camera → fire RPC, or the server's
# raycast direction disagrees with the client.
(( hits < 3 )) && { echo "FAIL: only $hits hits (expected >= 3) — real-aim path is broken"; ok=false; }

# Confirm A's try_fire() actually returned true some number of times
# (otherwise our client-side ammo / cooldown gate is blocking everything).
fired_ok=$(grep -E "try_fire\(\) returned true [0-9]+ times" "$A_LOG" | head -1 || echo "")
fired_n=$(echo "$fired_ok" | grep -oE "[0-9]+" | head -1)
fired_n=${fired_n:-0}
echo "A: try_fire returned true $fired_n times"
(( fired_n < 5 )) && { echo "FAIL: try_fire() rarely succeeded — ammo/cooldown gating wrong"; ok=false; }

if grep -qE "Parse Error|SCRIPT ERROR" "$SERVER_LOG" "$A_LOG" "$B_LOG"; then
	echo "FAIL: parse/script errors logged"
	grep -nE "Parse Error|SCRIPT ERROR" "$SERVER_LOG" "$A_LOG" "$B_LOG" | head -10
	ok=false
fi

$ok && { echo "PASS"; exit 0; } || { echo "FAIL"; exit 1; }
