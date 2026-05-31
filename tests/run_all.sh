#!/usr/bin/env bash
# Full test suite. Two-tier structure:
#   - tier 1: unit / single-process tests, serial (fast, ~30s total)
#   - tier 2: MP integration tests, parallel via xargs -P. Each MP test
#             binds a distinct port so they don't fight.
#
# Tweak the parallel width with PARALLEL=N env var. Default 2.
#   - PARALLEL=1 ≈ 175s (pure serial fallback)
#   - PARALLEL=2 ≈ 180s, stable on macOS
#   - PARALLEL=4 ≈ 60s when it works, but on macOS BSD xargs under
#     resource pressure (4 tests × ~3 Godot procs each = 12+ concurrent
#     Godot processes) some workers get SIGKILL'd between `bash $cmd`
#     and the rc write — observable as "produced no rc marker" on 6-8
#     tests despite their test logs ending in PASS. Bump cautiously and
#     only on a beefy machine.
#
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
PARALLEL="${PARALLEL:-2}"
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
run_serial "spawn_clearance_test (no spawn point embedded in a wall)" \
    "$GODOT" --headless --path "$PROJ" tests/spawn_clearance_test.tscn
run_serial "match_mode_test (FFA/ELIM/RACE win conditions)" \
    "$GODOT" --headless --path "$PROJ" tests/match_mode_test.tscn
run_serial "lag_comp_test (history record + sample interpolation)" \
    "$GODOT" --headless --path "$PROJ" tests/lag_comp_test.tscn
run_serial "hud_signal_test (hp/ammo/weapon_switched bindings)" \
    "$GODOT" --headless --path "$PROJ" tests/hud_signal_test.tscn
run_serial "killcam_test (death replay: visibility restore + cam/ghost teardown)" \
    "$GODOT" --headless --path "$PROJ" tests/killcam_test.tscn
if [ -f "$PROJ/tests/run_hitbox_geometry_test.sh" ]; then
    run_serial "hitbox_geometry (per-skin coverage)" \
        "$PROJ/tests/run_hitbox_geometry_test.sh"
fi
if [ -f "$PROJ/tests/run_listen_host_weapon_tick_test.sh" ]; then
    run_serial "listen_host_weapon_tick (host ticks remote cooldown + reload)" \
        "$PROJ/tests/run_listen_host_weapon_tick_test.sh"
fi
if [ -f "$PROJ/tests/run_player_collision_test.sh" ]; then
    run_serial "player_collision (player↔player blocks, no Jolt Y-explosion)" \
        "$PROJ/tests/run_player_collision_test.sh"
fi
if [ -f "$PROJ/tests/run_ability_buff_test.sh" ]; then
    run_serial "ability_buff (server-side buff state + damage mult)" \
        "$PROJ/tests/run_ability_buff_test.sh"
fi
if [ -f "$PROJ/tests/run_map_sync_test.sh" ]; then
    run_serial "map_sync (client swaps to server's map_path)" \
        "$PROJ/tests/run_map_sync_test.sh"
fi
if [ -f "$PROJ/tests/run_staging_lobby_test.sh" ]; then
    run_serial "staging_lobby (HOST/JOIN/START state machine)" \
        "$PROJ/tests/run_staging_lobby_test.sh"
fi
if [ -f "$PROJ/tests/run_room_manager_test.sh" ]; then
    run_serial "room_manager (server-side room CRUD)" \
        "$PROJ/tests/run_room_manager_test.sh"
fi
if [ -f "$PROJ/tests/run_room_rpc_test.sh" ]; then
    run_serial "room_rpc (NetRpc signals → RoomManager handlers)" \
        "$PROJ/tests/run_room_rpc_test.sh"
fi
if [ -f "$PROJ/tests/run_room_scenes_parse_test.sh" ]; then
    run_serial "room_scenes_parse (room_browser/room_lobby instantiate)" \
        "$PROJ/tests/run_room_scenes_parse_test.sh"
fi

# ── Single-process feature tests (added 2026-05-30 — were drifting outside
#    the suite). All godot×1, no background DS, so they belong in tier 1. ──
for spec in \
    "grenade::run_grenade_test.sh::throwable AoE math" \
    "lean::run_lean_test.sh::lean/peek server-authoritative" \
    "slide::run_slide_test.sh::slide tech (sprint+crouch lunge)" \
    "prediction::run_prediction_test.sh::DS-client local prediction" \
    "map_validate::run_map_validate_test.sh::all maps spawn-point + collision" \
    "database::run_database_test.sh::sqlite accounts/economy/password hash" \
    "bot_map_engage::run_bot_map_engage_test.sh::bot un-frozen + engages" \
    "weapons_dialog_builder::run_weapons_dialog_builder_test.sh::catalog builder" \
    "hud_font_inheritance::run_hud_font_inheritance_test.sh::HUD font no-tofu" \
    "rematch_reject::run_rematch_reject_test.sh::rematch reject feedback" \
    "respawn_input_tick_reset::run_respawn_input_tick_reset_test.sh::respawn resets input tick" \
    "room_world::run_room_world_test.sh::per-room world isolation" \
    "main_menu_compression::run_main_menu_compression_test.sh::menu fits viewport" \
    "concurrent_match::run_concurrent_match_test.sh::concurrent rooms isolated" \
    "replay_player::run_replay_player_test.sh::replay JSON recorder↔player contract" \
    ; do
    name="${spec%%::*}"; rest="${spec#*::}"; runner="${rest%%::*}"; desc="${rest##*::}"
    if [ -f "$PROJ/tests/$runner" ]; then
        run_serial "$name ($desc)" "$PROJ/tests/$runner"
    fi
done

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
  "mp_host_collision_guard:::$PROJ/tests/run_mp_host_collision_guard_test.sh"
  "server_boot_test:::$PROJ/tests/run_server_boot_test.sh"
  # input_rpc_test RETIRED 2026-05-31 — tested a dead pre-room "bare peer, no
  # join" path (roomless player never simulated). Input→server-movement coverage
  # lives in two_client / three_client / real_aim / match_e2e (room flow). See
  # run_input_rpc_test.sh header + .agent/test.md 2026-05-31.
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
