extends Node
## Singleton (autoload) — single source of truth for tick rates, RPC names,
## and message schemas. Mirrors /Users/longmao/projects/pvp-game/server.js socket
## events, but moves command authority to the server.

# ── Timing ──────────────────────────────────────────────────────────────────
const TICK_RATE := 30                          # server simulation tick
const TICK_DELTA := 1.0 / float(TICK_RATE)
const SNAPSHOT_INTERPOLATION_MS := 100         # client renders remote entities this far behind
const LAG_COMP_HISTORY_TICKS := 60             # ~2s ring buffer of player positions

# ── Process role detection ──────────────────────────────────────────────────
## C7: tells client-only autoloads (Settings, ProcAudio, ServerDiscovery,
## StatsStore) whether the current process was launched with `--server`.
## Loaded BEFORE every other autoload (this file is #1 in project.godot),
## so it's safe to call from inside their `_ready`.
## STATIC so callers reach it through a `const NetProtocol = preload(...)` class
## reference instead of the autoload global. That keeps the referencing scripts
## compilable in standalone load paths (smoke `--script`, replay CLI tools, cold
## cache) where the autoload singleton isn't registered. Always call it as
## `NetProtocol.is_dedicated_server_boot()` via that preloaded const — never on
## the live autoload instance, which would warn STATIC_CALLED_ON_INSTANCE.
static func is_dedicated_server_boot() -> bool:
	return "--server" in OS.get_cmdline_user_args()


# ── Trust-boundary thresholds (used by server-side validators) ─────────────
# Max input-tick jump per accepted frame. A legit 30Hz client advances by 1;
# we allow a generous burst to absorb hitch-then-resync without lockout.
const MAX_INPUT_TICK_JUMP := 240                # 8s of catchup at 30Hz
# Lower 16 bits of the bitfield are defined (see INPUT_* below). Mask client
# input to ignore unknown bits — defends against a peer setting high bits to
# trigger nothing-visible side effects in future RPC fields.
const INPUT_BITS_MASK := 0x3FFFF   # 18 bits — bits 16/17 are LEAN_LEFT/RIGHT
# Max aim delta between successive accepted input frames AND between the last
# input frame and a fire RPC's yaw/pitch. PI ≈ 180° per ~33ms is well above
# real human flick speed, so this only flags obvious snap-aim teleports.
const MAX_AIM_DELTA_RAD := PI

# Anti-cheat speed monitor: legitimate move_speed=5 + speed-pad mults can hit
# ~15 m/s. Anything higher is suspicious enough to log. We only WARN today
# (server prints a line, no auto-kick) so a legit edge case doesn't ban
# real players; the log line + repeated offender count is enough signal to
# investigate manually.
const SUSPECT_HORIZ_SPEED := 20.0
# Headshot ratio threshold for a statistical anti-cheat alert. A genuinely
# excellent player tops out around 50-60% headshots; anyone consistently
# above this across enough kills is probably aimbotting.
const SUSPECT_HEADSHOT_RATIO := 0.85
# Minimum sample size before headshot-ratio alert fires (avoid 1/1 = 100%
# false positives on a single lucky shot).
const SUSPECT_HEADSHOT_MIN_KILLS := 12

# ── Damage ──────────────────────────────────────────────────────────────────
const PLAYER_MAX_HP := 300                     # matches server.js PLAYER_MAX_HP
const HEAL_CAP := 150                          # matches server.js healSelf clamp

# ── Economy (server.js constants) ───────────────────────────────────────────
const STARTER_CREDITS := 500
const TRIAL_DIVISOR := 20
const ADMIN_PASS_COST := 300
const ADMIN_PASS_LENGTH_MS := 600_000           # 10 minutes
const UPGRADE_COSTS := [30, 60, 120]            # fragments per upgrade level
const MAX_UPGRADE_LEVELS_PER_WEAPON := 3
const CHEST_PRICE_COMMON := 120
const CHEST_PRICE_RARE := 400
const FRAGMENT_UNLOCK_COST := 100
const WHEEL_PAID_COST := 100

# ── RPC names (collected so grep finds every caller in one place) ──────────
# Client → Server
const RPC_CLIENT_HELLO       := &"client_hello"            # (username, auth_token)
const RPC_CLIENT_SEND_INPUT  := &"client_send_input"       # (tick, input_bits, look_yaw, look_pitch, fire, ability)
const RPC_CLIENT_RESPAWN     := &"client_request_respawn"
const RPC_CLIENT_CHAT        := &"client_chat_line"        # (text, color, emoji)
const RPC_CLIENT_LOBBY_JOIN  := &"client_join_lobby"       # (mode_id)
const RPC_CLIENT_LOBBY_LEAVE := &"client_leave_lobby"
const RPC_CLIENT_LOBBY_READY := &"client_set_ready"        # (ready, fill_bots)
const RPC_CLIENT_TEAM_SWAP   := &"client_swap_team"
const RPC_CLIENT_LOADOUT     := &"client_set_loadout"      # (primary, secondary, melee, support ids)

# Server → Client
const RPC_SERVER_WELCOME     := &"server_welcome"          # (your_peer_id, server_tick)
const RPC_SERVER_SNAPSHOT    := &"server_send_snapshot"    # (tick, entity_states[])
const RPC_SERVER_APPLY_DMG   := &"server_apply_damage"     # (target_peer, new_hp, src_peer, weapon_id, headshot)
const RPC_SERVER_PLAYER_DIE  := &"server_player_died"      # (target_peer, killer_peer)
const RPC_SERVER_RESPAWN     := &"server_player_respawned" # (target_peer, x, y, z)
const RPC_SERVER_BULLET      := &"server_bullet_fired"     # (id, owner, origin, dir, weapon_id)
const RPC_SERVER_CHAT        := &"server_chat_line"        # (peer, text, color, emoji)
const RPC_SERVER_LOBBY_STATE := &"server_lobby_state"      # (mode, players[])
const RPC_SERVER_LOBBY_START := &"server_lobby_start"      # (match_id, mode, team, bots[])
const RPC_SERVER_LOBBY_ERR   := &"server_lobby_error"      # (error_msg)
const RPC_SERVER_MATCH_END   := &"server_match_ended"      # (winning_team, scores)


# ── Input bitfield (packed into a single int per tick) ─────────────────────
const INPUT_FORWARD  := 1 << 0
const INPUT_BACK     := 1 << 1
const INPUT_LEFT     := 1 << 2
const INPUT_RIGHT    := 1 << 3
const INPUT_JUMP     := 1 << 4
const INPUT_CROUCH   := 1 << 5
const INPUT_SPRINT   := 1 << 6
const INPUT_FIRE     := 1 << 7
const INPUT_ADS      := 1 << 8
const INPUT_ABILITY  := 1 << 9
const INPUT_RELOAD   := 1 << 10
const INPUT_MELEE    := 1 << 11
const INPUT_SWAP_1   := 1 << 12
const INPUT_SWAP_2   := 1 << 13
const INPUT_SWAP_3   := 1 << 14
const INPUT_SWAP_4   := 1 << 15
const INPUT_LEAN_LEFT  := 1 << 16
const INPUT_LEAN_RIGHT := 1 << 17


# ── Schema helpers ─────────────────────────────────────────────────────────
# Snapshot entity record — keep flat dicts (cheap to serialize over WebSocket):
#   { "p": peer_id, "pos": Vector3, "yaw": float, "pitch": float,
#     "hp": int, "weapon": &"ak20", "flags": int }
const ENTITY_FLAG_ADS       := 1 << 0
const ENTITY_FLAG_RELOADING := 1 << 1
const ENTITY_FLAG_DEAD      := 1 << 2
const ENTITY_FLAG_INVULN    := 1 << 3   # spawn shield
const ENTITY_FLAG_BOT       := 1 << 4
const ENTITY_FLAG_LEAN_LEFT  := 1 << 5   # peeking left  — remote clients tilt the model
const ENTITY_FLAG_LEAN_RIGHT := 1 << 6   # peeking right
