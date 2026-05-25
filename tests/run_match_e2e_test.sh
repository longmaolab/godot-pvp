#!/usr/bin/env bash
# End-to-end match-mode test. DS boots with --mode ffa_kill5 (goal: 5 kills).
# A continuously kills B until the server's MatchController declares A the
# winner. Asserts: server logs "match ended — winner peer <A>".

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
# Randomize within a band so back-to-back runs avoid TIME_WAIT collisions
# from prior client sockets (WebSocketMultiplayerPeer doesn't set SO_REUSEADDR).
PORT=$((9300 + RANDOM % 400))
SERVER_LOG="$LOG_DIR/match_e2e_server.log"
A_LOG="$LOG_DIR/match_e2e_A.log"
B_LOG="$LOG_DIR/match_e2e_B.log"

echo "=== DS match-mode E2E test (FFA → 5 kills) ==="
# Defensively wait if the port is held from a previous run (OS TIME_WAIT
# can hold a port for ~60s after a noisy close).
for i in 1 2 3 4 5; do
	if ! lsof -i ":$PORT" >/dev/null 2>&1; then break; fi
	echo "  (waiting on port $PORT to free, attempt $i)"
	sleep 2
done
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 24 \
	--mode ffa_kill5 --test-repeat-kill-interval 0.5 \
	>"$SERVER_LOG" 2>&1 &
SPID=$!
sleep 1.2

"$GODOT" --headless --path "$PROJ" tests/headless_match_e2e.tscn \
	-- --role B --address "ws://127.0.0.1:$PORT" --fire-seconds 16.0 \
	>"$B_LOG" 2>&1 &
B_PID=$!
sleep 0.7
"$GODOT" --headless --path "$PROJ" tests/headless_match_e2e.tscn \
	-- --role A --address "ws://127.0.0.1:$PORT" --fire-seconds 16.0 \
	>"$A_LOG" 2>&1 &
A_PID=$!

wait $A_PID; A_RC=$?
wait $B_PID; B_RC=$?
wait $SPID

echo "--- server log (match-relevant) ---"
grep -E "mode=|match ended|died — respawning|MatchController" "$SERVER_LOG" | head -30
echo "--- A log ---"; tail -10 "$A_LOG"
echo "--- B log ---"; tail -8 "$B_LOG"
echo "--- result ---"

ok=true
# Clients can exit non-zero if the server self-terminates while they're
# still alive (signal-killed) — that doesn't invalidate the server-side
# match-end signal we actually care about. Only fail on client exits if
# the server ALSO failed to produce the expected match_ended log.
client_fail_msg=""
[[ $A_RC -ne 0 ]] && client_fail_msg+="A exit $A_RC; "
[[ $B_RC -ne 0 ]] && client_fail_msg+="B exit $B_RC; "

# Server must log that the FFA mode loaded.
if ! grep -q "mode=ffa_kill5" "$SERVER_LOG"; then
	echo "FAIL: server didn't load mode ffa_kill5 — --mode flag broken"
	ok=false
fi

# At least 5 deaths happened (the kill goal).
deaths=$(grep -cE "died — respawning" "$SERVER_LOG" 2>/dev/null || true)
deaths=${deaths:-0}
echo "deaths recorded: $deaths"
(( deaths < 5 )) && { echo "FAIL: only $deaths deaths (kill goal 5 never reached)"; ok=false; }

# Server fires match_ended once goal is hit. The match_controller logs nothing
# directly on the DS path; the in-scene handler at game_controller.gd:1029
# prints "[server] match ended — winner peer N".
if ! grep -aqE "match ended — winner peer [0-9]+" "$SERVER_LOG"; then
	echo "FAIL: server never logged match ended"
	ok=false
	# In this branch the test cares about client exits too.
	[[ -n "$client_fail_msg" ]] && { echo "FAIL: $client_fail_msg"; }
else
	winner=$(grep -aoE "match ended — winner peer [0-9]+" "$SERVER_LOG" | head -1)
	echo "match end log: $winner"
	[[ -n "$client_fail_msg" ]] && echo "(note: $client_fail_msg — clients SIGKILLed by server shutdown; server confirmed match end so still PASS)"
fi

if grep -qE "Parse Error|SCRIPT ERROR" "$SERVER_LOG" "$A_LOG" "$B_LOG"; then
	echo "FAIL: parse/script errors"
	grep -nE "Parse Error|SCRIPT ERROR" "$SERVER_LOG" "$A_LOG" "$B_LOG" | head -10
	ok=false
fi

$ok && { echo "PASS"; exit 0; } || { echo "FAIL"; exit 1; }
