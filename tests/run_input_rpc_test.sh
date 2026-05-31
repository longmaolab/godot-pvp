#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ RETIRED 2026-05-31 — removed from tests/run_all.sh. Do not treat as a gate. ║
# ╚══════════════════════════════════════════════════════════════════════════╝
# This DS-M2-era test connects a bare client (client_hello, NO room join) and
# streams client_send_input, expecting the server-side player to move. After the
# room refactor (F3-M*) a roomless peer's player is spawned into the global
# players_root, but physics/matches run inside each room's RoomWorld SubViewport
# — so that player is never simulated (DS log: spawn at y=1.0, y stays 1.000, no
# gravity, no movement). Real clients ALWAYS join a room, so this path is dead.
# Input→server-movement is covered by the room-flow MP tests that DO pass:
# two_client / three_client / real_aim / match_e2e. Root cause: .agent/test.md
# 2026-05-31. The harness (headless_input_client.gd) is kept so this can be
# revived as a proper room-flow test (create_room → start_match → send input).
echo "[RETIRED] input_rpc_test — dead pre-room path; coverage in two/three_client/real_aim. Skipping."
exit 0

# ── Original DS-M2 body kept below for revival reference (unreachable) ───────
# Two subtests: A) INPUT_FORWARD → final.z « spawn.z;  B) zero bits → final.z ≈ spawn.z.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"

# INPUT_FORWARD = 1<<0 = 1 ; INPUT_BACK = 1<<1 = 2 (see net_protocol.gd)
# Random high ports — fixed 9102/9103 caused "bind failed" → inconclusive runs
# when DS tests run concurrently / a prior socket lingered (codexreview 05-31).
PORT_A=$((9400 + RANDOM % 300))
PORT_B=$((PORT_A + 1))

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
