#!/usr/bin/env bash
# DS-M4 verification: server spawns with a stationary DummyTarget. A test
# client connects, aims at the dummy, and holds FIRE input. The server's
# authoritative raycast must land hits — proven by the dummy's take_hit
# emissions logged on the server side.
#
# Aim math: spawn pos (0,1,0), head offset +1.0 → camera world (0, 2, 0).
# Dummy root (0,0,-10); body hitbox center (0, 0.8, -10). Aim from camera:
#   dy = 0.8 - 2 = -1.2,  dz = -10 → pitch = atan(-1.2 / 10) ≈ -0.119 rad
# Round to -0.12 for the test (lands on body upper half).

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
PORT=9105
SERVER_LOG="$LOG_DIR/fire_server.log"
CLIENT_LOG="$LOG_DIR/fire_client.log"

# INPUT_FIRE = 1 << 7 = 128
FIRE_BIT=128

echo "=== DS-M4 server-fire test ==="
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 7 --dummy \
	>"$SERVER_LOG" 2>&1 &
SPID=$!
sleep 1.4

"$GODOT" --headless --path "$PROJ" \
	tests/headless_input_client.tscn -- \
	--address "ws://127.0.0.1:$PORT" --duration 2.0 --bits "$FIRE_BIT" \
	--aim-yaw 0.0 --aim-pitch -0.12 \
	>"$CLIENT_LOG" 2>&1 &
CPID=$!

wait $CPID
wait $SPID

echo "--- server log (tail) ---"
tail -30 "$SERVER_LOG"
echo "--- client log (tail) ---"
tail -15 "$CLIENT_LOG"

ok=true

# Check 1: server logged dummy hits (>= 3 — at AK20's 600 RPM over 2s
# we should land maybe 15-20 if the aim is right; ≥3 is a safe floor).
hit_count=$(grep -c "dummy hit:" "$SERVER_LOG" 2>/dev/null || true)
hit_count=${hit_count:-0}
echo "dummy hits on server: $hit_count"
if (( hit_count < 3 )); then
	echo "FAIL: only $hit_count dummy hits (expected >= 3)"
	ok=false
fi

# Check 2: no script errors.
if grep -qE "ERROR:|Parse Error|SCRIPT ERROR" "$SERVER_LOG"; then
	echo "FAIL: server logged errors"
	grep -E "ERROR:|Parse Error|SCRIPT ERROR" "$SERVER_LOG" | head -5
	ok=false
fi

if $ok; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
