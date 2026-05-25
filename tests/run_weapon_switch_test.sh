#!/usr/bin/env bash
# Weapon swap + per-weapon ammo + auto-reload integration. A connects with
# the default loadout, fires ak20, swaps to srx, swaps back, drains a mag,
# verifies reload completes.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
PORT=9207
SERVER_LOG="$LOG_DIR/weapon_switch_server.log"
A_LOG="$LOG_DIR/weapon_switch_A.log"
B_LOG="$LOG_DIR/weapon_switch_B.log"

echo "=== DS weapon-switch test ==="
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 12 \
	>"$SERVER_LOG" 2>&1 &
SPID=$!
sleep 1.2

"$GODOT" --headless --path "$PROJ" tests/headless_weapon_switch.tscn \
	-- --role B --address "ws://127.0.0.1:$PORT" \
	>"$B_LOG" 2>&1 &
B_PID=$!
sleep 0.7
"$GODOT" --headless --path "$PROJ" tests/headless_weapon_switch.tscn \
	-- --role A --address "ws://127.0.0.1:$PORT" \
	>"$A_LOG" 2>&1 &
A_PID=$!

wait $A_PID; A_RC=$?
wait $B_PID; B_RC=$?
wait $SPID

echo "--- server log (weapon-relevant) ---"
grep -E "weapon=|\[server\] hit:" "$SERVER_LOG" | head -30
echo "--- A log ---"; tail -25 "$A_LOG"
echo "--- B log ---"; tail -5 "$B_LOG"
echo "--- result ---"

ok=true
[[ $A_RC -ne 0 ]] && { echo "FAIL: A exit $A_RC"; ok=false; }
[[ $B_RC -ne 0 ]] && { echo "FAIL: B exit $B_RC"; ok=false; }

# Fires must reach the server with BOTH ak20 and srx weapon ids — proves the
# RPC carried the swap.
ak_fires=$(grep -cE "weapon=ak20" "$SERVER_LOG" 2>/dev/null || true)
srx_fires=$(grep -cE "weapon=srx" "$SERVER_LOG" 2>/dev/null || true)
ak_fires=${ak_fires:-0}
srx_fires=${srx_fires:-0}
echo "server received ak20 fires=$ak_fires srx fires=$srx_fires"
(( ak_fires < 1 ))  && { echo "FAIL: expected >= 1 ak20 fire (got $ak_fires)"; ok=false; }
(( srx_fires < 1 )) && { echo "FAIL: expected >= 1 srx fire (got $srx_fires)"; ok=false; }

# Distinct damage values from ak20 vs srx → different weapon-resolution paths.
# ak20 body = 25, srx body = 95, srx headshot instakill ⇒ 190 effectively.
distinct_dmg=$(grep -oE "dmg=[0-9]+\.[0-9]+" "$SERVER_LOG" | sort -u | wc -l | tr -d ' ')
distinct_dmg=${distinct_dmg:-0}
echo "distinct damage values: $distinct_dmg"
(( distinct_dmg < 2 )) && { echo "FAIL: expected >= 2 distinct dmg values (proves weapon swap honored), got $distinct_dmg"; ok=false; }

# A's final PASS line confirms reload completed and ammo refilled.
if ! grep -q "PASS — weapon swap + per-weapon ammo + reload all OK" "$A_LOG"; then
	echo "FAIL: A did not reach final PASS line — check A_LOG"
	ok=false
fi

if grep -qE "Parse Error|SCRIPT ERROR" "$SERVER_LOG" "$A_LOG" "$B_LOG"; then
	echo "FAIL: parse/script errors"
	grep -nE "Parse Error|SCRIPT ERROR" "$SERVER_LOG" "$A_LOG" "$B_LOG" | head -10
	ok=false
fi

$ok && { echo "PASS"; exit 0; } || { echo "FAIL"; exit 1; }
