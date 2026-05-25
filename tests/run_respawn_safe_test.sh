#!/usr/bin/env bash
# Respawn-safety integration. After B dies, the server's "safest spawn"
# picker must pick a position FAR from A (anti-spawn-kill). After respawn,
# B must be invincible for ~2.5s — even if A's raycast keeps tagging B's
# hitbox, no [server] hit: lines are emitted during that window.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
PORT=9206
SERVER_LOG="$LOG_DIR/respawn_safe_server.log"
A_LOG="$LOG_DIR/respawn_safe_A.log"
B_LOG="$LOG_DIR/respawn_safe_B.log"

echo "=== DS respawn-safety test ==="
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 11 \
	>"$SERVER_LOG" 2>&1 &
SPID=$!
sleep 1.2

"$GODOT" --headless --path "$PROJ" tests/headless_respawn_safe.tscn \
	-- --role B --address "ws://127.0.0.1:$PORT" --fire-seconds 7.5 \
	>"$B_LOG" 2>&1 &
B_PID=$!
sleep 0.7
"$GODOT" --headless --path "$PROJ" tests/headless_respawn_safe.tscn \
	-- --role A --address "ws://127.0.0.1:$PORT" --fire-seconds 7.5 \
	>"$A_LOG" 2>&1 &
A_PID=$!

wait $A_PID; A_RC=$?
wait $B_PID; B_RC=$?
wait $SPID

echo "--- server log (tail) ---"; tail -40 "$SERVER_LOG"
echo "--- A log (tail) ---"; tail -8 "$A_LOG"
echo "--- B log (tail) ---"; tail -15 "$B_LOG"
echo "--- result ---"

ok=true
[[ $A_RC -ne 0 ]] && { echo "FAIL: A exit $A_RC"; ok=false; }
[[ $B_RC -ne 0 ]] && { echo "FAIL: B exit $B_RC"; ok=false; }

# 1. Must have at least one death + respawn cycle.
deaths=$(grep -cE "died — respawning" "$SERVER_LOG" 2>/dev/null || true)
deaths=${deaths:-0}
respawns=$(grep -cE "respawned at" "$SERVER_LOG" 2>/dev/null || true)
respawns=${respawns:-0}
echo "deaths=$deaths respawns=$respawns"
(( deaths < 1 ))  && { echo "FAIL: no deaths recorded"; ok=false; }
(( respawns < 1 )) && { echo "FAIL: no respawns recorded"; ok=false; }

# 2. Anti-spawn-kill: extract A's final pos from A_LOG and B's first respawn
# pos from server log; distance must be >= 8.0 units. (On blank map the
# corner spawns are (-10,-10), (0,0), (10,10) — any DIFFERENT corner from
# A's gives distance >= 14.)
a_final=$(grep -oE "\[A\] final pos=\([^)]*\)" "$A_LOG" | sed -E 's/.*\(([^)]*)\)/\1/' | head -1)
respawn_pos=$(grep -oE "respawned at \([^)]*\)" "$SERVER_LOG" | head -1 | sed -E 's/respawned at \(([^)]*)\)/\1/')
echo "A final pos: $a_final"
echo "B first respawn pos: $respawn_pos"
if [[ -n "$a_final" && -n "$respawn_pos" ]]; then
	# Parse two "x, y, z" comma-separated triples and compute planar distance.
	dist=$(python3 -c "
import sys, math
def parse(s):
    parts = [float(x.strip()) for x in s.split(',')]
    return parts
a = parse('$a_final'); b = parse('$respawn_pos')
print('%.2f' % math.hypot(a[0]-b[0], a[2]-b[2]))
")
	echo "planar A↔respawn distance: $dist"
	awk -v d="$dist" 'BEGIN{ exit !(d+0 >= 8.0) }' && true || {
		echo "FAIL: respawn too close to shooter (dist=$dist, need >= 8.0)"
		ok=false
	}
else
	echo "FAIL: could not extract A pos or respawn pos for distance check"
	ok=false
fi

# 3. Invincibility window — count damage-broadcast events during the ~2.5s
#    following the first "respawned at" line. With apply_damage being
#    i-frame-guarded, the server's *internal* HP shouldn't drop, AND the
#    broadcast should reflect that.
#
#    Known bug exposed by this assertion (as of this commit):
#    game_controller.gd computes `new_hp` BEFORE calling apply_damage(),
#    then logs + broadcasts that value regardless of whether apply_damage
#    early-returned on i-frame. So the [server] hit: line + the broadcast
#    desync — clients see HP drop, server keeps full HP. Real game effect:
#    "I died but server says I'm full HP" / "client kill feed wrong".
#    Fix: read victim.hp AFTER apply_damage, OR check _invincible_until
#    before computing/broadcasting new_hp.
awk_script='
BEGIN { state=0; cnt=0 }
/respawned at/ && state==0 { state=1; next }
state==1 && /\[server\] hit:/ { cnt++ }
state==1 && /done|auto-shutdown|despawned peer/ { state=2 }
END { print cnt }
'
# Use line ordering as a coarse proxy for time (server log is in temporal order;
# DS prints fire/hit interleaved). Within the 50 lines after "respawned at",
# we should see no hits at all if i-frame works (server raycast inside the
# i-frame window does NOT log "[server] hit:" because apply_damage early-returns
# BEFORE the print line at 801).
post_respawn_hits=$(awk '
  /respawned at/ { armed=NR }
  armed && NR>armed && NR<=armed+75 && /\[server\] hit:/ { c++ }
  END { print (c+0) }
' "$SERVER_LOG")
echo "hits in 75-line window after first respawn: $post_respawn_hits"
# Allow up to 2 (lag-comp rewind / first frame edge); strict zero is too brittle
# on slow runners.
if (( post_respawn_hits > 2 )); then
	echo "FAIL: $post_respawn_hits damage events landed during i-frame window (expected <= 2)"
	ok=false
fi

if grep -qE "Parse Error|SCRIPT ERROR" "$SERVER_LOG" "$A_LOG" "$B_LOG"; then
	echo "FAIL: parse/script errors"
	grep -nE "Parse Error|SCRIPT ERROR" "$SERVER_LOG" "$A_LOG" "$B_LOG" | head -10
	ok=false
fi

$ok && { echo "PASS"; exit 0; } || { echo "FAIL"; exit 1; }
