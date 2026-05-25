# Dedicated Server — Operations + Cut-Scope

Status: **DS-M1 → DS-M5 landed.** Main pipeline (world boot, input RPC,
snapshot broadcast, authoritative fire, server-driven respawn) all verified
end-to-end with 6 dedicated integration tests, plus 6 legacy tests still green.

## What works today

```
                                  ┌──────────────────────────┐
                                  │  Godot DS (headless)     │
                                  │                          │
                                  │  ▸ Loads game.tscn       │
                                  │  ▸ Map + collision world │
                                  │  ▸ Authoritative physics │
                                  │  ▸ 30Hz snapshot tick    │
                                  │  ▸ Server raycast fire   │
                                  │  ▸ Lag-comp rewind        │
                                  │  ▸ Server-driven respawn │
                                  └─────────────▲────────────┘
                                                │
                              client_send_input │ server_send_snapshot
                              client_fire       │ server_apply_damage
                              client_hello      │ server_welcome
                                                │ server_mode_info
                                                │ server_player_respawned
                                                ▼
                                  ┌──────────────────────────┐
                                  │  Godot Client            │
                                  │                          │
                                  │  ▸ Reads Input.* → bits  │
                                  │  ▸ Sends input @ 30Hz    │
                                  │  ▸ Renders snapshot      │
                                  │  ▸ entity_interpolator    │
                                  │      100ms buffered     │
                                  └──────────────────────────┘
```

## Running a dedicated server

## Port convention

| Port | Bound by | Purpose |
|---|---|---|
| **7777** | main menu `HOST` button | listen-host (in-editor quick test, host is also a player) |
| **7777** | `./scripts/start_server.sh` / `--server` | dedicated server (separate process, server doesn't play, fully authoritative) |

Different ports so you can run BOTH on the same machine for comparison.
The JOIN field placeholder defaults to `ws://127.0.0.1:7777` (DS).

```bash
# Default port 7777, blank map, runs forever:
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/longmao/projects/godot-pvp -- --server

# Pick map + port:
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/longmao/projects/godot-pvp -- \
    --server --port 7777 --map koth

# Available maps: blank, battlefield, koth, trenches, skydock

# Auto-shutdown after N seconds (for tests / CI):
godot --headless --path . -- --server --port 7777 --seconds 60

# Spawn a stationary DummyTarget for shooting tests (DS-M4 test hook):
godot --headless --path . -- --server --dummy

# Test-only: kill the first connected player N seconds after connect
# (used by DS-M5 respawn test):
godot --headless --path . -- --server --test-kill-after 1.5
```

## Connecting from the menu

1. Start a DS as above (Terminal 1)
2. Press F5 in the Godot editor to open `main_menu.tscn` (Terminal 2 / editor)
3. Leave the join-address field blank (auto-fills `ws://127.0.0.1:7777`) OR type your own URL
4. Click **JOIN**
5. The client handshakes → server sends `server_mode_info(is_dedicated=true)` →
   the local player switches to snapshot-only render mode
6. WASD moves the server-side player; mouse aims; LMB fires (all authoritative)

## Verified integration tests

| Test | Asserts |
|---|---|
| `tests/run_server_boot_test.sh` (M1) | server boots world, spawns peer on connect, despawns on disconnect |
| `tests/run_input_rpc_test.sh` (M2) | server moves player when client sends FORWARD; doesn't move with bits=0 |
| `tests/run_snapshot_test.sh` (M3) | client receives ≥20 snapshots/s; snapshot z agrees with server final z (dz=0) |
| `tests/run_fire_test.sh` (M4) | server raycasts using authoritative position; lands hits on dummy |
| `tests/run_respawn_test.sh` (M5) | server detects death; 3s respawn; client gets server_player_respawned RPC; HP back to 300 |
| `tests/run_boot_test.sh` | main_menu boots clean, no script errors |

Plus 6 legacy unit/integration tests (smoke, practice, bot, death/respawn,
match_mode, lag_comp) all continue to pass.

## Architecture notes

### PlayerController state matrix

| Scenario | is_local | is_human_input | use_remote_input | is_snapshot_only | Behavior |
|---|---|---|---|---|---|
| Practice mode local | ✔ | ✔ | ✘ | ✘ | Reads Input → simulates → renders |
| Practice mode bot | ✘ | ✘ | ✘ | ✘ | BotPlayer overrides movement |
| Listen-host owner | ✔ | ✔ | ✘ | ✘ | Same as practice + broadcasts `_net_apply_state` |
| Listen-host remote ghost | ✘ | ✘ | ✘ | ✘ | Receives `_net_apply_state`, lerps |
| **DS server-side player** | ✘ | ✘ | **✔** | ✘ | Server simulates from `push_remote_input` queue |
| **DS client own player** | ✔ | ✔ | ✘ | **✔** | Sends input + renders snapshot |
| **DS client other peer** | ✘ | ✘ | ✘ | **✔** | Pure snapshot ghost |

### What the server is now genuinely authoritative over

- **Position**: client sends bits, server computes velocity + collision, broadcasts via snapshot. A client that sends fake transforms is ignored.
- **HP / damage**: server raycasts using its own known positions; only the server can produce `server_apply_damage`.
- **Death / respawn**: server detects HP≤0, schedules timer, picks spawn point, broadcasts respawn.
- **Lag-comp rewind**: when peer A fires, targets are rewound to where they were at A's view time (`ping/2 + interp_delay`), so a hit on A's screen is a hit on the server.

### What the client still does locally (intentional, for responsiveness)

- Camera kick / muzzle flash / tracer visuals on the local player only (cosmetic — server doesn't care).
- Mouse-look writes `_aim_yaw/_aim_pitch` immediately; these are sent up. Aim feels instant.
- HUD bind to local player, damage flash, kill confirm — driven by signals.

---

# DS-M6 Cut-Scope Inventory

Things explicitly **NOT** on the DS critical path. They exist as data / scenes
but don't close the loop in the new server-authoritative architecture.

## Loadout / economy ↔ combat (parked)

- Server uses hardcoded `DEFAULT_LOADOUT` (AK20, SG8, SRX, Railgun) — does not read `Settings.purchased[]`.
- `Settings.upgrades[]` (damage/mag/reload levels) defined but **not applied** to server damage calc.
- Currency / fragments / chests / wheel / bundles all UI-only. No server integration.
- **To do**: when client connects, client sends `client_set_loadout(primary_id, secondary_id, ...)` after spawn → server validates ownership against a future `account` table → server swaps the spawn loadout.

## Arcade modes (parked — only race/ffa/elim work end-to-end)

| Mode | rule_script | Win condition wired? |
|---|---|---|
| 1v1 / 2v2 / 3v3 elim | match_controller built-in | ✅ |
| FFA kill_goal | match_controller built-in | ✅ |
| TDM race | match_controller built-in | ✅ |
| KOTH | `koth_rule.gd` | ❌ hill-zone score not summed to win |
| Gun Game | `gungame_rule.gd` | ⚠️ weapon ladder partial; no win |
| OITC | `oitc_rule.gd` | ⚠️ 1-bullet ammo cap only; no kill-goal win |
| Infection | `infection_rule.gd` | ⚠️ patient zero + spread only; no survivor-timeout win |
| Juggernaut | — | ❌ not started |
| Sniper Only | — | ❌ not started |
| Speedrun | — | ❌ not started |
| Battle Royale | — | ❌ not started |
| D-Day | — | ❌ not started |
| Frontlines | — | ❌ not started |
| Last Stand | — | ❌ not started |

## Multiplayer cosmetic sync (parked)

- **Skins**: each peer renders other peers with `skin_index = peer_id % 18`, not the actual chosen skin. Need a `client_set_identity(name, skin_idx)` RPC right after welcome.
- **Names**: same — peers show as `P<id>` not the chosen name.
- **Killfeed**: only fires for local kills via `fired` signal. Server-side kills (someone else killing someone else) don't reach the local HUD.

## Input fidelity (parked)

- **Client prediction**: DS client doesn't simulate locally → ~50-100ms of perceived input lag depending on RTT. The `client_prediction.gd` skeleton exists but isn't wired. Fix would be: simulate locally with input bits + reconcile when snapshot arrives with mismatch.
- **Touch controls**: `touch_controls.tscn` ported from arena-shooter-3d but not wired to the new input bit path.
- **Ammo in HUD**: server has the authoritative ammo count, snapshot doesn't include it yet. HUD shows stale value.

## Pre-existing concerns ([per code review](#))

- HOST mode (listen-host) still trusts client positions via `_net_apply_state`. The DS pipeline is what supersedes it. Recommend either porting listen-host to also use input + snapshot (1 day of work — most code is shared) or removing the listen-host flow entirely.
- Bot AI runs on whoever spawned it (currently practice mode = local client). On DS we'd want server-side bot ticks. Not implemented — bots are still practice-only.

---

# Next-up suggestions (when picking back up)

Priority order based on impact / cost:

1. **Skin + name sync** (1-2 hours) — meaningful identity in MP. Add `client_set_identity` RPC at hello time; include in spawn RPC payload.
2. **Server-driven killfeed broadcast** (1 hour) — `server_player_died(killer, victim, weapon)` RPC; HUD listens.
3. **Loadout from Settings.purchased** (2-3 hours) — server reads `client_set_loadout` after welcome; validates id against weapon registry; swaps `p.loadout` and `p.weapon_def`.
4. **Ammo in snapshot** (30 min) — add `ammo_in_mag` to entity dict; HUD reads it.
5. **Client prediction + reconciliation** (4-6 hours) — the polish that makes the game feel responsive. Worth doing if first impressions matter.
6. **Arcade mode closures** (1-2 days per mode) — when the core feels good, expand mode coverage one at a time.
