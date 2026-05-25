#!/usr/bin/env bash
# Convenience launcher for the dedicated server.
#
# Defaults:
#   port  = 7777  (matches the JOIN field placeholder in main_menu)
#   map   = blank
#   bots  = none yet (DS-M6 cut-scope)
#
# Usage:
#   ./scripts/start_server.sh                       # blank map on :7777
#   ./scripts/start_server.sh battlefield 7777      # battlefield on :7777
#   ./scripts/start_server.sh koth 8888 dummy       # koth on :8888 with dummy target
#
# Logs go to tests/.logs/server_live.log

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/server_live.log"

MAP="${1:-blank}"
PORT="${2:-7777}"
DUMMY_FLAG=""
if [[ "${3:-}" == "dummy" ]]; then
	DUMMY_FLAG="--dummy"
fi

echo "Starting Godot PvP dedicated server"
echo "  map  : $MAP"
echo "  port : $PORT"
echo "  log  : $LOG"
echo "  join from client: ws://127.0.0.1:$PORT"
echo "  Press Ctrl+C to stop."

exec "$GODOT" --headless --path "$PROJ" -- \
	--server --port "$PORT" --map "$MAP" $DUMMY_FLAG \
	2>&1 | tee "$LOG"
