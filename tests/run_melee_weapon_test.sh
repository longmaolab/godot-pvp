#!/usr/bin/env bash
# Unit test for EQUIPPED melee weapons (dagger / hammer) — swing damage,
# no-ammo, cooldown + range gating via try_fire()'s slot=="melee" path.
# (Distinct from run_melee_test.sh, which covers the universal melee KEY.)
set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/melee_weapon.log"
echo "=== melee weapon (dagger / hammer) test ==="
"$GODOT" --headless --path "$PROJ" -s tests/melee_weapon_test.gd >"$LOG" 2>&1 &
PID=$!; ( sleep 30 && kill -9 $PID 2>/dev/null && echo "[killed]" >>"$LOG" ) & K=$!; wait $PID 2>/dev/null; kill "$K" 2>/dev/null
echo "--- log tail ---"; tail -12 "$LOG"
if grep -q "^  PASS — " "$LOG"; then echo "PASS"; exit 0
elif grep -q "^  FAIL:" "$LOG"; then echo "FAIL"; exit 1
else echo "INCONCLUSIVE"; exit 2; fi
