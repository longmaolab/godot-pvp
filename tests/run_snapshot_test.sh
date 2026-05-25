#!/usr/bin/env bash
# DS-M3 verification: client connects to DS, sends FORWARD input, observes
# server_send_snapshot broadcasts. Asserts:
#   1. >= 20 snapshots received during ~2s
#   2. Last snapshot's self.z agrees with server's final position (server is
#      genuinely broadcasting authoritative state, not zeros)
#   3. server_mode_info was received with is_dedicated=true

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
PORT=9104
SERVER_LOG="$LOG_DIR/snapshot_server.log"
CLIENT_LOG="$LOG_DIR/snapshot_client.log"

echo "=== DS-M3 snapshot test ==="
"$GODOT" --headless --path "$PROJ" -- --server --port "$PORT" --seconds 6 \
	>"$SERVER_LOG" 2>&1 &
SPID=$!
sleep 1.2

"$GODOT" --headless --path "$PROJ" \
	tests/headless_input_client.tscn -- \
	--address "ws://127.0.0.1:$PORT" --duration 1.5 --bits 1 \
	>"$CLIENT_LOG" 2>&1 &
CPID=$!

wait $CPID
wait $SPID

echo "--- server log (tail) ---"
tail -20 "$SERVER_LOG"
echo "--- client log (tail) ---"
tail -20 "$CLIENT_LOG"

ok=true

# Check 1: client received >= 20 snapshots.
snap_count=$(grep -oE "PASS — sent [0-9]+ input frames, [0-9]+ snapshots received" "$CLIENT_LOG" | grep -oE "[0-9]+ snapshots" | grep -oE "^[0-9]+" || echo 0)
if [[ -z "$snap_count" || "$snap_count" -lt 20 ]]; then
	echo "FAIL: only $snap_count snapshots received (expected >= 20)"
	ok=false
fi

# Check 2: server_mode_info delivered.
if ! grep -q "server is_dedicated=true" "$CLIENT_LOG"; then
	echo "FAIL: client never received server_mode_info"
	ok=false
fi

# Check 3: snapshot self.z agrees with server final.z (within 0.5m).
client_z=$(grep -oE "last snapshot self pos: \(-?[0-9.]+, -?[0-9.]+, -?[0-9.]+\)" "$CLIENT_LOG" | sed -E 's/.*\((-?[0-9.]+), (-?[0-9.]+), (-?[0-9.]+)\).*/\3/' || echo "")
server_z=$(grep "final position" "$SERVER_LOG" | sed -E 's/.*\(([^,]+), ([^,]+), ([^)]+)\).*/\3/' || echo "")
if [[ -z "$client_z" || -z "$server_z" ]]; then
	echo "FAIL: could not extract z positions (client='$client_z' server='$server_z')"
	ok=false
else
	dz=$(python3 -c "print(abs($client_z - $server_z))")
	threshold_ok=$(python3 -c "print(1 if $dz < 0.5 else 0)")
	echo "client_z=$client_z server_z=$server_z dz=$dz"
	if [[ "$threshold_ok" != "1" ]]; then
		echo "FAIL: client snapshot z and server final z disagree by $dz (>0.5)"
		ok=false
	fi
fi

if grep -qE "ERROR:|Parse Error|SCRIPT ERROR" "$SERVER_LOG"; then
	echo "FAIL: server logged errors"
	grep -E "ERROR:|Parse Error|SCRIPT ERROR" "$SERVER_LOG" | head -5
	ok=false
fi

if $ok; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
