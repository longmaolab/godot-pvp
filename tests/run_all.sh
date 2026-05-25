#!/usr/bin/env bash
# Full test suite. Two-tier structure:
#   - tier 1: unit / single-process tests, serial (fast, ~30s total)
#   - tier 2: MP integration tests, 4-way parallel via xargs -P (each binds
#             a distinct port so they don't fight). Without parallelism this
#             used to take ~5 min; with 4-way it's ~90-120s.
#
# Tweak the parallel width with PARALLEL=N env var. Default 4.
# Exits 0 if every test passed; non-zero if any failed.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs/run_all"
mkdir -p "$LOG_DIR"

# ── tier 2 worker: invoked once per spec by xargs -P ──────────────────────
# IMPORTANT: this branch runs BEFORE the parent's `rm -f *.rc` cleanup so
# concurrent workers don't delete each other's freshly-written rc markers
# (that was the bug behind "produced no rc marker" for 13/16 tests).
# Spec format: "<name>:::<path-to-script>"  →  rc to $LOG_DIR/<name>.rc
if [[ "${1:-}" = "--worker" ]]; then
    spec="$2"
    name="${spec%%:::*}"
    cmd="${spec##*:::}"
    bash "$cmd" > "$LOG_DIR/$name.log" 2>&1
    rc=$?
    echo "$rc" > "$LOG_DIR/$name.rc"
    if [[ $rc -eq 0 ]]; then
        echo "  ✓ $name"
    else
        echo "  ✗ $name (rc=$rc, see $LOG_DIR/$name.log)"
    fi
    exit 0
fi

# Parent-only setup beyond here. (Workers exited above.)
# Wipe stale per-test rc markers from a previous run.
rm -f "$LOG_DIR"/*.rc 2>/dev/null
PARALLEL="${PARALLEL:-4}"
START_TS=$(date +%s)

pass_count=0
fail_count=0
failed_names=""

# ── tier 1 helper ─────────────────────────────────────────────────────────
run_serial() {
    local name="$1"
    shift
    echo
    echo "─── [serial] $name ───"
    if "$@"; then
        echo "  ✓ $name"
        pass_count=$((pass_count + 1))
    else
        echo "  ✗ $name"
        fail_count=$((fail_count + 1))
        failed_names="$failed_names $name"
    fi
}

echo "═════════════════════════════════════════"
echo "  TIER 1: unit + single-process tests"
echo "═════════════════════════════════════════"

run_serial "smoke_test (data + math)" \
    "$PROJ/tests/run_smoke_test.sh"
run_serial "boot_test (main_menu boots clean)" \
    "$PROJ/tests/run_boot_test.sh"
run_serial "practice_integration (player vs dummy)" \
    "$GODOT" --headless --path "$PROJ" tests/practice_integration.tscn
run_serial "bot_integration (AI hunts stationary dummy)" \
    "$GODOT" --headless --path "$PROJ" tests/bot_integration.tscn
run_serial "death_respawn_test (signal sigs + respawn refill)" \
    "$GODOT" --headless --path "$PROJ" tests/death_respawn_test.tscn
run_serial "match_mode_test (FFA/ELIM/RACE win conditions)" \
    "$GODOT" --headless --path "$PROJ" tests/match_mode_test.tscn
run_serial "lag_comp_test (history record + sample interpolation)" \
    "$GODOT" --headless --path "$PROJ" tests/lag_comp_test.tscn
run_serial "hud_signal_test (hp/ammo/weapon_switched bindings)" \
    "$GODOT" --headless --path "$PROJ" tests/hud_signal_test.tscn
if [ -f "$PROJ/tests/run_hitbox_geometry_test.sh" ]; then
    run_serial "hitbox_geometry (per-skin coverage)" \
        "$PROJ/tests/run_hitbox_geometry_test.sh"
fi
if [ -f "$PROJ/tests/run_listen_host_weapon_tick_test.sh" ]; then
    run_serial "listen_host_weapon_tick (host ticks remote cooldown + reload)" \
        "$PROJ/tests/run_listen_host_weapon_tick_test.sh"
fi

echo
echo "═════════════════════════════════════════"
echo "  TIER 2: MP integration tests (parallel x$PARALLEL)"
echo "═════════════════════════════════════════"
echo

# Each spec: "<name>:::<absolute-path-to-script>"  ← :::  separator avoids
# colliding with shell-meta in the path.
specs=(
  "multiplayer_integration:::$PROJ/tests/run_multiplayer_test.sh"
  "mp_game_test:::$PROJ/tests/run_mp_game_test.sh"
  "mp_hit_test:::$PROJ/tests/run_mp_hit_test.sh"
  "server_boot_test:::$PROJ/tests/run_server_boot_test.sh"
  "input_rpc_test:::$PROJ/tests/run_input_rpc_test.sh"
  "snapshot_test:::$PROJ/tests/run_snapshot_test.sh"
  "fire_test:::$PROJ/tests/run_fire_test.sh"
  "respawn_test:::$PROJ/tests/run_respawn_test.sh"
  "two_client_test:::$PROJ/tests/run_two_client_test.sh"
  "rejoin_test:::$PROJ/tests/run_rejoin_test.sh"
  "multi_rejoin_test:::$PROJ/tests/run_multi_rejoin_test.sh"
  "three_client_test:::$PROJ/tests/run_three_client_test.sh"
  "real_aim_test:::$PROJ/tests/run_real_aim_test.sh"
  "weapon_switch_test:::$PROJ/tests/run_weapon_switch_test.sh"
  "respawn_safe_test:::$PROJ/tests/run_respawn_safe_test.sh"
  "match_e2e_test:::$PROJ/tests/run_match_e2e_test.sh"
)
[ -f "$PROJ/tests/run_mp_burst_hit_test.sh" ] && \
  specs+=("mp_burst_hit_test:::$PROJ/tests/run_mp_burst_hit_test.sh")

# Pipe specs into xargs, one per line. -P4 -L1 = up to 4 in flight, one
# spec per invocation. Each worker writes its rc to LOG_DIR/<name>.rc.
SCRIPT="$0"
printf '%s\n' "${specs[@]}" | xargs -P "$PARALLEL" -I {} bash "$SCRIPT" --worker '{}'

# Collect rc markers and tally.
for spec in "${specs[@]}"; do
    name="${spec%%:::*}"
    rc_file="$LOG_DIR/$name.rc"
    if [[ -f "$rc_file" ]]; then
        rc=$(cat "$rc_file")
        if [[ "$rc" = "0" ]]; then
            pass_count=$((pass_count + 1))
        else
            fail_count=$((fail_count + 1))
            failed_names="$failed_names $name"
        fi
    else
        echo "  ! $name produced no rc marker — treating as failed"
        fail_count=$((fail_count + 1))
        failed_names="$failed_names $name(no-rc)"
    fi
done

ELAPSED=$(($(date +%s) - START_TS))
echo
echo "═════════════════════════════════════════"
echo "  SUMMARY"
echo "═════════════════════════════════════════"
echo "  passed: $pass_count"
echo "  failed: $fail_count"
echo "  elapsed: ${ELAPSED}s"
if [[ $fail_count -gt 0 ]]; then
    echo "  failed tests:$failed_names"
    echo "  full logs: $LOG_DIR/<name>.log"
fi
[ "$fail_count" -eq 0 ] && exit 0 || exit 1
