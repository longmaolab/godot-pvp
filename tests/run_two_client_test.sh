#!/usr/bin/env bash
# Two-client DS integration test — the test the user's complaint requires:
# does shooter→target damage actually flow end-to-end?
#
# Layout: DS on PORT, two full game.tscn clients connect. They spawn at the
# blank map's Spawn0=(0,1,0) and Spawn1=(10,1,10) markers (server picks based
# on distance scoring; with 2 peers each gets a different marker).
# Shooter is told to aim at the OTHER spawn's location and hold FIRE.
# Server raycasts authoritatively and (if aim is right) drops the victim's HP.
#
# Asserts:
#   1. Both clients spawn
#   2. Server logs at least 1 server_apply_damage broadcast
#   3. Victim's HP from server's final position log is < 300 (damage landed)

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
PORT=9201
SERVER_LOG="$LOG_DIR/two_client_server.log"
A_LOG="$LOG_DIR/two_client_A.log"
B_LOG="$LOG_DIR/two_client_B.log"

# Server spawn-point selection on blank map:
#   - B connects first → gets Spawn0 = (0, 1, 0)
#   - A connects second → smart-spawn picks farthest from B → Spawn1 = (10, 1, 10)
# Shooter A aims FROM (10, 2, 10) eye TOWARD victim B at (0, 0.8, 0) body hitbox.
#   delta: dx=-10, dz=-10, dy=-1.2
# In Godot dir = (-sin(yaw), -sin(pitch), -cos(yaw)). For dir = (-0.707, ?, -0.707):
#   -sin(yaw) = -0.707 → yaw = +π/4 ≈ +0.785
#   pitch = atan(dy / horiz) = atan(-1.2 / 14.14) ≈ -0.085 (look slightly down)
AIM_YAW=0.785
AIM_PITCH=-0.085
# INPUT_FIRE = 1 << 7 = 128
FIRE_BIT=128

echo "=== DS two-client fire test ==="
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 8 \
	>"$SERVER_LOG" 2>&1 &
SPID=$!
sleep 1.2

# Victim first so they're spawned and ready when shooter aims at their spawn.
"$GODOT" --headless --path "$PROJ" tests/headless_two_client.tscn \
	-- --role B --address "ws://127.0.0.1:$PORT" --wait 5.0 \
	>"$B_LOG" 2>&1 &
B_PID=$!
sleep 0.8

"$GODOT" --headless --path "$PROJ" tests/headless_two_client.tscn \
	-- --role A --address "ws://127.0.0.1:$PORT" --wait 4.0 \
	--aim-yaw "$AIM_YAW" --aim-pitch "$AIM_PITCH" --fire \
	>"$A_LOG" 2>&1 &
A_PID=$!

wait $A_PID
wait $B_PID
wait $SPID

echo "--- server log (tail) ---"
tail -30 "$SERVER_LOG"
echo "--- shooter (A) log (tail) ---"
tail -15 "$A_LOG"
echo "--- victim (B) log (tail) ---"
tail -15 "$B_LOG"

ok=true
# Server should log 2 spawns.
spawn_count=$(grep -c "spawned player for peer" "$SERVER_LOG" 2>/dev/null || true)
spawn_count=${spawn_count:-0}
if (( spawn_count < 2 )); then
	echo "FAIL: server didn't spawn 2 peers (got $spawn_count)"
	ok=false
fi
# Server should log at least 1 fire (push_remote_input → try_fire).
# We don't have a direct "fire happened" log on server, so we check for the
# victim's final position log including HP. Server logs final position as:
#   [server] peer <id> final position: (x, y, z)
# We need a separate HP log. Add it server-side if missing.

# Final HP is unreliable to assert on because the kill triggers respawn after
# 3s (server-driven) which restores HP. Instead assert that AT LEAST ONE
# server-side death happened — that proves the full server-authoritative chain
# (input RPC → server raycast → damage → death → respawn) is intact.
deaths=$(grep -cE "died — respawning" "$SERVER_LOG" 2>/dev/null || true)
deaths=${deaths:-0}
echo "server-detected deaths: $deaths"
if (( deaths < 1 )); then
	echo "FAIL: no server-side death detected — server raycast / damage path broken"
	ok=false
fi
# Also confirm at least a few damage applications happened server-side.
dmg_events=$(grep -cE "\[server\] hit:" "$SERVER_LOG" 2>/dev/null || true)
dmg_events=${dmg_events:-0}
echo "server damage events: $dmg_events"
if (( dmg_events < 3 )); then
	echo "FAIL: only $dmg_events damage events (expected >= 3 — fire path likely broken)"
	ok=false
fi

if grep -qE "Parse Error|SCRIPT ERROR" "$SERVER_LOG"; then
	echo "FAIL: server logged parse/script errors"
	grep -E "Parse Error|SCRIPT ERROR" "$SERVER_LOG" | head -5
	ok=false
fi

if $ok; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
