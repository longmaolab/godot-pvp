#!/usr/bin/env bash
# DS-M2 verification: a headless test client sends client_send_input RPCs to
# the dedicated server. The server simulates physics from those inputs and
# logs the player's final position before disconnect.
#
# We run TWO subtests:
#   A. INPUT_FORWARD bit set → expect final.z significantly less than spawn.z
#      (forward in Godot = -Z, so movement should be ~ -several meters)
#   B. zero bits          → expect final.z within ±0.5 of spawn.z
#
# B is the "did we accidentally always move?" guard.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"

# INPUT_FORWARD = 1<<0 = 1 ; INPUT_BACK = 1<<1 = 2 (see net_protocol.gd)
PORT_A=9102
PORT_B=9103

run_subtest() {
	local label="$1" port="$2" bits="$3" min_dz="$4" max_dz="$5"
	local server_log="$LOG_DIR/input_rpc_${label}_server.log"
	local client_log="$LOG_DIR/input_rpc_${label}_client.log"

	echo "--- subtest $label : bits=$bits expecting dz in [$min_dz, $max_dz] ---"
	"$GODOT" --headless --path "$PROJ" -- --server --port "$port" --seconds 6 \
		>"$server_log" 2>&1 &
	local spid=$!
	sleep 1.2

	"$GODOT" --headless --path "$PROJ" \
		tests/headless_input_client.tscn -- \
		--address "ws://127.0.0.1:$port" --duration 1.5 --bits "$bits" \
		>"$client_log" 2>&1 &
	local cpid=$!

	wait $cpid; local crc=$?
	wait $spid; local src=$?

	# Pull spawn z and final z from server log.
	local spawn_line final_line
	spawn_line=$(grep -m1 "spawned player for peer" "$server_log" || true)
	final_line=$(grep "final position" "$server_log" || true)
	if [[ -z "$spawn_line" || -z "$final_line" ]]; then
		echo "  FAIL[$label]: missing spawn/final log lines"
		echo "    spawn: $spawn_line"
		echo "    final: $final_line"
		return 1
	fi
	# Lines look like:
	#   [server] spawned player for peer N at (0.0, 1.0, 0.0)
	#   [server] peer N final position: (0.000, 1.000, -7.214)
	local spawn_z final_z
	spawn_z=$(echo "$spawn_line" | sed -E 's/.*\(([^,]+), ([^,]+), ([^)]+)\).*/\3/')
	final_z=$(echo "$final_line" | sed -E 's/.*\(([^,]+), ([^,]+), ([^)]+)\).*/\3/')
	local dz
	dz=$(python3 -c "print($final_z - $spawn_z)")

	echo "  spawn_z=$spawn_z final_z=$final_z dz=$dz"

	local ok
	ok=$(python3 -c "print(1 if $min_dz <= $dz <= $max_dz else 0)")
	if [[ "$ok" != "1" ]]; then
		echo "  FAIL[$label]: dz=$dz outside [$min_dz, $max_dz]"
		echo "  --- server log tail ---"
		tail -20 "$server_log"
		return 1
	fi
	if grep -qE "ERROR:|Parse Error|SCRIPT ERROR" "$server_log"; then
		echo "  FAIL[$label]: server logged errors"
		grep -E "ERROR:|Parse Error|SCRIPT ERROR" "$server_log" | head -5
		return 1
	fi
	echo "  PASS[$label]"
	return 0
}

echo "=== DS-M2 input-RPC test ==="

ok=true
# Subtest A: forward — player should move several meters in -Z.
if ! run_subtest "forward" "$PORT_A" 1 -20.0 -1.0; then ok=false; fi
# Subtest B: no input — player should stay near spawn (±0.5m on z).
if ! run_subtest "idle"    "$PORT_B" 0 -0.5  0.5;  then ok=false; fi

if $ok; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
