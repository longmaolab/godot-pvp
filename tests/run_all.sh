#!/usr/bin/env bash
# Run every M1 test in order. Exit non-zero on first failure.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"

pass_count=0
fail_count=0

run_one() {
    local name="$1"
    shift
    echo
    echo "========================================="
    echo "  TEST: $name"
    echo "========================================="
    if "$@"; then
        echo "  ✓ $name"
        pass_count=$((pass_count + 1))
    else
        echo "  ✗ $name"
        fail_count=$((fail_count + 1))
    fi
}

# 1. Unit smoke (parses + Resource loads + pure math).
run_one "smoke_test (data + math)" \
    "$GODOT" --headless --path "$PROJ" --script tests/smoke_test.gd

# 1b. Boot the actual main scene — catches runtime _ready errors that
#     pure-parse smoke tests miss (bad @onready paths, autoload init fails).
run_one "boot_test (main_menu boots clean)" \
    "$PROJ/tests/run_boot_test.sh"

# 2. Practice integration (real player + dummy + raycast hits).
run_one "practice_integration (player vs dummy)" \
    "$GODOT" --headless --path "$PROJ" tests/practice_integration.tscn

# 2b. AI bot integration (bot hunts dummy).
run_one "bot_integration (AI hunts stationary dummy)" \
    "$GODOT" --headless --path "$PROJ" tests/bot_integration.tscn

# 2bb. Death + respawn cycle (catches HUD signal-signature drift).
run_one "death_respawn_test (signal sigs + respawn refill)" \
    "$GODOT" --headless --path "$PROJ" tests/death_respawn_test.tscn

# 2c. Match-mode controller (FFA / ELIM / RACE win conditions).
run_one "match_mode_test (FFA/ELIM/RACE win conditions)" \
    "$GODOT" --headless --path "$PROJ" tests/match_mode_test.tscn

# 2d. LagCompensator history + interpolation math.
run_one "lag_comp_test (history record + sample interpolation)" \
    "$GODOT" --headless --path "$PROJ" tests/lag_comp_test.tscn

# NOTE: lag_comp_integration single-process test was experimental — the
# Area3D broadphase doesn't synchronously refresh on global_position writes,
# which makes the rewind-then-raycast assertion flaky in a single tick.
# The math is covered by lag_comp_test (unit), and the wired-up rewind path
# is exercised in mp_hit_test (which still passes with lag-comp enabled).

# 3. Multiplayer integration (real WebSocket client/server, NetRpc round-trip).
run_one "multiplayer_integration (server + client RPC)" \
    "$PROJ/tests/run_multiplayer_test.sh"

# 4. Multiplayer GAME-spawn integration (host + client both load game.tscn).
run_one "mp_game_test (host & client spawn each other)" \
    "$PROJ/tests/run_mp_game_test.sh"

# 5. Multiplayer SERVER-AUTHORITATIVE damage (client fires, server resolves).
run_one "mp_hit_test (server-authoritative damage)" \
    "$PROJ/tests/run_mp_hit_test.sh"
run_one "mp_burst_hit_test (listen-host accepts multi-shot burst)" \
    "$PROJ/tests/run_mp_burst_hit_test.sh"

# ── Dedicated server pipeline (DS-M1 → DS-M5) ────────────────────────────
run_one "server_boot_test  (DS-M1: world + handshake)" \
    "$PROJ/tests/run_server_boot_test.sh"
run_one "input_rpc_test    (DS-M2: client input → server sim)" \
    "$PROJ/tests/run_input_rpc_test.sh"
run_one "snapshot_test     (DS-M3: server snapshot → client interpolation)" \
    "$PROJ/tests/run_snapshot_test.sh"
run_one "fire_test         (DS-M4: server-authoritative hitscan)" \
    "$PROJ/tests/run_fire_test.sh"
run_one "respawn_test      (DS-M5: death + 3s respawn loop)" \
    "$PROJ/tests/run_respawn_test.sh"

# ── New end-to-end client tests (the user's actual flows) ─────────────────
run_one "two_client_test   (2 real clients on DS, A shoots B, damage lands)" \
    "$PROJ/tests/run_two_client_test.sh"
run_one "rejoin_test       (quit + rejoin: first client cleanly reconnects)" \
    "$PROJ/tests/run_rejoin_test.sh"
run_one "multi_rejoin_test (A+B in match, A leaves+rejoins, A still shoots B)" \
    "$PROJ/tests/run_multi_rejoin_test.sh"
run_one "three_client_test (3 clients, multi-shooter, mid-match leave)" \
    "$PROJ/tests/run_three_client_test.sh"
run_one "real_aim_test     (try_fire() real LMB path, not bypass-RPC)" \
    "$PROJ/tests/run_real_aim_test.sh"
run_one "hitbox_geometry    (HeadHitbox/BodyHitbox cover visible model for every skin)" \
    "$PROJ/tests/run_hitbox_geometry_test.sh"
run_one "weapon_switch_test (swap + per-weapon ammo + reload timer)" \
    "$PROJ/tests/run_weapon_switch_test.sh"
run_one "hud_signal_test   (hp_changed / ammo_changed / weapon_switched bindings)" \
    "$GODOT" --headless --path "$PROJ" tests/hud_signal_test.tscn
run_one "respawn_safe_test (anti-spawn-kill + post-respawn i-frame)" \
    "$PROJ/tests/run_respawn_safe_test.sh"
run_one "match_e2e_test    (DS + --mode ffa_kill5 + match_ended fires)" \
    "$PROJ/tests/run_match_e2e_test.sh"

echo
echo "========================================="
echo "  SUMMARY"
echo "========================================="
echo "  passed: $pass_count"
echo "  failed: $fail_count"
[ "$fail_count" -eq 0 ] && exit 0 || exit 1
