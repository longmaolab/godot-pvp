#!/usr/bin/env bash
# Fast smoke suite for iteration. Skips every MP integration test that has a
# `--seconds N` wall-clock budget. Target: < 30 seconds total.
#
# Use this while debugging; run `bash tests/run_all.sh` before commit / push.
#
# What's IN:
#   - smoke_test            (pure unit: data + math)
#   - boot_test             (main scene boots without _ready errors)
#   - practice_integration  (single-process player vs dummy)
#   - bot_integration       (single-process AI vs dummy)
#   - death_respawn_test    (signal sigs + ammo refill)
#   - match_mode_test       (FFA/ELIM/RACE win-condition unit)
#   - lag_comp_test         (history + interp math)
#   - hitbox_geometry       (per-skin hitbox coverage)
#   - hud_signal_test       (HUD bindings)
#
# What's OUT (gone to run_all.sh):
#   - every MP integration / DS-M* / two_client / rejoin / three_client /
#     real_aim / weapon_switch / respawn_safe / match_e2e / mp_hit_test
#     (each needs a server-lifetime budget; collectively dominates run_all.sh)

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
START_TS=$(date +%s)

pass_count=0
fail_count=0

run_one() {
    local name="$1"
    shift
    echo
    echo "─── $name ───"
    if "$@"; then
        echo "  ✓ $name"
        pass_count=$((pass_count + 1))
    else
        echo "  ✗ $name"
        fail_count=$((fail_count + 1))
    fi
}

# Run smoke through the wrapper (NOT the bare .gd) so engine-side compile/
# parse errors become hard fails. smoke_test.gd only inspects load_threaded
# status, which reports a broken script as "loaded" — invoking it directly
# (the old behaviour here) let real Compile Errors pass as PASS. run_all.sh
# already routes through this wrapper; run_quick.sh now matches.
run_one "smoke_test" \
    "$PROJ/tests/run_smoke_test.sh"
run_one "boot_test" \
    "$PROJ/tests/run_boot_test.sh"
run_one "practice_integration" \
    "$GODOT" --headless --path "$PROJ" tests/practice_integration.tscn
run_one "bot_integration" \
    "$GODOT" --headless --path "$PROJ" tests/bot_integration.tscn
run_one "death_respawn_test" \
    "$GODOT" --headless --path "$PROJ" tests/death_respawn_test.tscn
run_one "match_mode_test" \
    "$GODOT" --headless --path "$PROJ" tests/match_mode_test.tscn
run_one "lag_comp_test" \
    "$GODOT" --headless --path "$PROJ" tests/lag_comp_test.tscn
# hitbox_geometry is single-process (no network) — fast enough for smoke.
if [ -f "$PROJ/tests/run_hitbox_geometry_test.sh" ]; then
    run_one "hitbox_geometry" \
        "$PROJ/tests/run_hitbox_geometry_test.sh"
fi
run_one "hud_signal_test" \
    "$GODOT" --headless --path "$PROJ" tests/hud_signal_test.tscn
# grenade_test — throwable AoE math (no network, no projectile spawn — just
# direct _explode() math). 5s. Added 2026-05-27 alongside the 5 new throwables.
if [ -f "$PROJ/tests/run_grenade_test.sh" ]; then
    run_one "grenade_test" \
        "$PROJ/tests/run_grenade_test.sh"
fi

ELAPSED=$(($(date +%s) - START_TS))
echo
echo "═════════════════════════════════════════"
echo "  passed: $pass_count   failed: $fail_count   in ${ELAPSED}s"
echo "═════════════════════════════════════════"
[ "$fail_count" -eq 0 ] && exit 0 || exit 1
