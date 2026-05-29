extends Node
## Autoload — owns every @rpc method shared between client and server.
##
## Placing every RPC on a single autoload guarantees the node path matches on
## both sides (Godot routes RPCs by NodePath). The methods are bare relays:
## they emit signals so the actual game logic (MatchAuthority on server,
## GameController on client) stays decoupled and testable.

# ── server-side signals (fired when an RPC arrives from a client) ─────────
signal client_hello_received(peer_id: int, username: String)
signal client_input_received(peer_id: int, tick: int, bits: int, yaw: float, pitch: float)
## Fire intent now carries the shooter's instantaneous aim so the server can
## raycast at the EXACT direction the client was looking, not the interp-delayed
## view it has of the shooter's transform.
signal client_fire_received(peer_id: int, weapon_id: StringName, yaw: float, pitch: float)
## Listen-host clients send this when they press the ability key, so the
## server's view of the player can mirror buff/powershot state. DS clients
## already trigger ability server-side via the INPUT_ABILITY edge in
## push_remote_input — sending the RPC there too is harmless (the cooldown
## guard inside try_activate_ability makes the second call a no-op).
signal client_ability_received(peer_id: int)
signal client_switch_weapon_received(peer_id: int, weapon_id: StringName)
signal client_chat_received(peer_id: int, text: String, color: Color)

# ── Lobby/room RPCs (Phase 1 — see .agent/lobby_plan.md). All client→server,
#    handled by RoomManager autoload which gates on is_server() and talks
#    back through the server→client RPCs below.
signal client_list_rooms_received(peer_id: int)
signal client_create_room_received(peer_id: int, map_path: String, mode_def_path: String)
signal client_join_room_received(peer_id: int, room_id: String)
signal client_leave_room_received(peer_id: int)
signal client_start_match_received(peer_id: int)
## Phase 2: lobby identity + ready toggle. Profile carries name + skin
## index, so the lobby shows "Anna · Char C" rather than "Player 12345".
## Ready is its own RPC because it changes much more frequently and we
## want to broadcast only the bit that flipped, not re-send name/skin.
signal client_set_lobby_profile_received(peer_id: int, name: String, skin: int)
signal client_set_ready_received(peer_id: int, ready: bool)
## Persistence (P-M3+): client identifies itself with a device-local
## uuid, server replies with the canonical profile + economy snapshot.
## After bootstrap, mutations go through the typed RPCs below; server
## echoes the updated row back so the client cache stays in sync.
signal client_request_profile_received(peer_id: int, device_id: String, auth_token: String, local_name: String, local_skin: int)
signal client_set_player_name_received(peer_id: int, name: String)
signal client_set_skin_index_received(peer_id: int, skin: int)
signal client_purchase_weapon_received(peer_id: int, weapon_id: String, price: int)
signal client_open_chest_received(peer_id: int, kind: String)
signal client_apply_upgrade_received(peer_id: int, weapon_id: String, stat: String, level: int)
signal client_spin_wheel_received(peer_id: int)
signal client_request_leaderboard_received(peer_id: int)
## P-M7 real accounts: opt-in registration + login. Anonymous tokens stay
## working for guests; converting to a real account merges the existing
## anonymous row by passing the device_id alongside the new credentials.
signal client_register_account_received(peer_id: int, device_id: String, handle: String, password: String)
signal client_login_received(peer_id: int, handle: String, password: String)
## Cheat / unlock code redemption. Client sends the raw user-typed string
## (lowercased server-side); server looks it up in unlock_codes.gd, grants
## the reward, marks the code as redeemed for this account so the same
## code can't be reused.
signal client_redeem_code_received(peer_id: int, code: String)

# ── client-side signals (fired when an RPC arrives from the server) ──────
signal server_welcome_received(your_peer: int, server_tick: int)
signal server_snapshot_received(tick: int, entities: Array)
signal server_damage_received(target: int, new_hp: float, src: int, weapon: StringName, headshot: bool)
signal server_chat_received(peer: int, text: String, color: Color)
# DS-M3: server tells the client what kind of host it is right after welcome
# (true = dedicated → client must send input + render from snapshot only).
signal server_mode_info_received(is_dedicated: bool)
## Server tells the client which map file is actually loaded server-side.
## The menu's MAP picker is host-only — when a peer JOINs, this RPC arrives
## during sync_request and the client swaps off whatever local map it
## happened to load. Without it the two sides render different geometries
## while sharing server-authoritative positions (host's KOTH wall = invisible
## on a client that picked Trenches → bullets pass through it visually,
## players fall into pits that don't exist for them, etc).
signal server_map_info_received(map_path: String)
## R11: same pattern as server_map_info but for the ModeDef resource. Client
## menu's MODE picker used to silently mismatch the server (server runs
## ffa_kill5 + client picked 10v10 → score limit reports wrong number on HUD).
## Server sends its requester's room's `mode_def.resource_path` during sync;
## client loads and assigns it locally so HUD / mode-specific UI renders
## against the real authority. Server is still 100% authoritative for win
## conditions; this is presentation-only on the client.
signal server_mode_def_received(mode_path: String)
## Throwable spawn — server broadcasts when a thrown weapon's projectile
## starts its flight. Client uses `weapon_id` to look up explode_radius +
## visual mesh, `origin` + `velocity` + `fuse_seconds` to deterministically
## integrate the same gravity-driven trajectory locally (no per-tick
## position sync needed, since the throw is short — 1-3s). proj_id is a
## monotonic counter, used to pair the explode RPC with the right visual.
signal server_throwable_spawn_received(proj_id: int, weapon_id: StringName, origin: Vector3, velocity: Vector3)
## Throwable explode — server broadcasts on detonation (contact OR fuse).
## Client spawns explosion VFX at `position` and frees its visual proxy.
signal server_throwable_explode_received(proj_id: int, position: Vector3)
## Host clicked START in the menu's staging area; all clients should leave
## the lobby state and load the game scene now. The host's map/mode picks
## are already authoritative via _launch_game → server_map_info during
## sync_request, so this RPC carries no payload — it's just "go".
signal server_match_starting_received()
# Server says "no, can't start match" — reason is a short machine-readable
# tag (room_gone / not_host / already_running / no_room) the client UI maps
# to a human message. See server_start_match_failed below.
signal server_start_match_failed_received(reason: String)

# ── Lobby/room replies (server → client). RoomManager broadcasts to the
#    relevant audience (requester only for list, all members for state, evicted
#    peers for destroyed).
signal server_room_list_received(rooms: Array)
signal server_room_joined_received(room_id: String, room_state: Dictionary)
signal server_room_join_failed_received(reason: String)
signal server_room_state_received(room_state: Dictionary)
signal server_room_destroyed_received(room_id: String)
## Server sends this when the match for `room_state.id` is over. Includes
## the fresh room state so the room_lobby that's about to load can read it
## from Settings.pending_room_state without a separate round-trip — avoids
## the race where the broadcaster could fire before the scene loaded.
signal server_match_ended_received(room_state: Dictionary)
## In-match scoreboard payload. `rows` is an Array of Dictionaries:
## { peer: int, name: String, skin: int, kills: int, deaths: int }.
## Fired from the server side whenever a kill flips a room's scores;
## scoped to that room's peers. Receiver-side: HUD.scoreboard refreshes.
signal server_score_update_received(rows: Array)
## Persistence: server pushes the full profile snapshot (account + economy
## + owned weapons + upgrades). Client mirrors into Settings autoload.
signal server_profile_received(profile: Dictionary)
## Per-action ack. ok=true → mutation applied + snapshot already pushed
## in a follow-up server_profile broadcast. ok=false → reason string
## (insufficient credits, already owned, …).
signal server_action_result_received(action: String, ok: bool, reason: String)
## Leaderboard top-N (joined with account names, ready to render).
signal server_leaderboard_received(rows: Array)
## Reward popup payload — chest open / wheel spin return values that
## the HUD can animate. Profile snapshot also gets pushed alongside.
signal server_reward_received(kind: String, reward: Dictionary)
# DS-M5: server announces respawn so the client can update its view.
signal server_respawn_received(peer: int, pos: Vector3)
# C6: explicit server-driven death event. Carries the killer peer so the kill
# feed / kill confirm on every client agrees with the server, and so clients
# no longer have to infer death from an HP-broadcast race.
signal server_death_received(victim_peer: int, killer_peer: int, weapon: StringName, headshot: bool)


# ── client → server ──────────────────────────────────────────────────────
@rpc("any_peer", "reliable", "call_remote")
func client_hello(username: String) -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_hello_received.emit(peer, username)


@rpc("any_peer", "unreliable_ordered", "call_remote")
func client_send_input(tick: int, bits: int, yaw: float, pitch: float) -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_input_received.emit(peer, tick, bits, yaw, pitch)


@rpc("any_peer", "reliable", "call_remote")
func client_fire(weapon_id: StringName, yaw: float, pitch: float) -> void:
	var peer := multiplayer.get_remote_sender_id()
	# Gate at the RPC edge — fire_resolver's per-shot pipeline (lag-comp
	# rewind + raycast + restore) costs real CPU, so we want to bail BEFORE
	# emitting the signal rather than after running the work.
	if not _check_rpc_rate(peer, "fire"):
		return
	client_fire_received.emit(peer, weapon_id, yaw, pitch)


@rpc("any_peer", "reliable", "call_remote")
func client_use_ability() -> void:
	var peer := multiplayer.get_remote_sender_id()
	if not _check_rpc_rate(peer, "ability"):
		return
	client_ability_received.emit(peer)


# P1-8: server-authoritative current weapon. Client equip_slot fires this so
# the host's view of the player switches in lockstep. Without it the server
# kept thinking the client was still on its initial weapon, and fire_resolver
# accepted ANY weapon_id from the client's loadout — a tampered client could
# pass an SRX weapon_id while holding an AK20 and get SRX damage every shot.
@rpc("any_peer", "reliable", "call_remote")
func client_switch_weapon(weapon_id: StringName) -> void:
	var peer := multiplayer.get_remote_sender_id()
	# Reuse the lobby/profile budget — switches are user-driven, not a
	# tight loop. 6/2s is enough for legitimate hot-swap UX.
	if not _check_rpc_rate(peer, "profile"):
		return
	client_switch_weapon_received.emit(peer, weapon_id)


# ── Lobby/room RPCs (client → server). All are dumb relays — RoomManager
#    listens on the signals above and does the actual logic.
@rpc("any_peer", "reliable", "call_remote")
func client_list_rooms() -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_list_rooms_received.emit(peer)


@rpc("any_peer", "reliable", "call_remote")
func client_create_room(map_path: String, mode_def_path: String) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if not _check_rpc_rate(peer, "create"):
		return
	client_create_room_received.emit(peer, map_path, mode_def_path)


@rpc("any_peer", "reliable", "call_remote")
func client_join_room(room_id: String) -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_join_room_received.emit(peer, room_id)


@rpc("any_peer", "reliable", "call_remote")
func client_leave_room() -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_leave_room_received.emit(peer)


@rpc("any_peer", "reliable", "call_remote")
func client_start_match() -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_start_match_received.emit(peer)


@rpc("any_peer", "reliable", "call_remote")
func client_set_lobby_profile(name: String, skin: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if not _check_rpc_rate(peer, "profile"):
		return
	client_set_lobby_profile_received.emit(peer, name, skin)


@rpc("any_peer", "reliable", "call_remote")
func client_set_ready(ready: bool) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if not _check_rpc_rate(peer, "ready"):
		return
	client_set_ready_received.emit(peer, ready)


# ── Persistence RPCs (P-M3 to P-M7) ──────────────────────────────────────
# All client→server. Sender's net peer_id is used to look up which DB
# account it bound to (server tracks peer_id → account_id mapping in
# game_controller). Mutations return via server_action_result + a fresh
# server_profile snapshot.

@rpc("any_peer", "reliable", "call_remote")
func client_request_profile(device_id: String, auth_token: String, local_name: String, local_skin: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	# Allocate a row on first contact; gate to stop a peer from spamming
	# bind requests with rotating device_ids to fill the accounts table.
	if not _check_rpc_rate(peer, "bind"):
		return
	client_request_profile_received.emit(peer, device_id, auth_token, local_name, local_skin)


@rpc("any_peer", "reliable", "call_remote")
func client_set_player_name(name: String) -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_set_player_name_received.emit(peer, name)


@rpc("any_peer", "reliable", "call_remote")
func client_set_skin_index(skin: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_set_skin_index_received.emit(peer, skin)


@rpc("any_peer", "reliable", "call_remote")
func client_purchase_weapon(weapon_id: String, price: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_purchase_weapon_received.emit(peer, weapon_id, price)


@rpc("any_peer", "reliable", "call_remote")
func client_open_chest(kind: String) -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_open_chest_received.emit(peer, kind)


@rpc("any_peer", "reliable", "call_remote")
func client_apply_upgrade(weapon_id: String, stat: String, level: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_apply_upgrade_received.emit(peer, weapon_id, stat, level)


@rpc("any_peer", "reliable", "call_remote")
func client_spin_wheel() -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_spin_wheel_received.emit(peer)


@rpc("any_peer", "reliable", "call_remote")
func client_request_leaderboard() -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_request_leaderboard_received.emit(peer)


@rpc("any_peer", "reliable", "call_remote")
func client_register_account(device_id: String, handle: String, password: String) -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_register_account_received.emit(peer, device_id, handle, password)


@rpc("any_peer", "reliable", "call_remote")
func client_login(handle: String, password: String) -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_login_received.emit(peer, handle, password)


# Unlock code redemption — server validates against unlock_codes.gd table.
@rpc("any_peer", "reliable", "call_remote")
func client_redeem_code(code: String) -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_redeem_code_received.emit(peer, code)


# Per-peer chat throttle. Allow CHAT_BURST messages within CHAT_WINDOW_MS,
# then silently drop until the window slides. Keeps a single peer from
# flooding all clients via the reliable broadcast path.
const CHAT_MAX_LEN := 240
const CHAT_BURST := 5
const CHAT_WINDOW_MS := 4000
var _chat_rate_state: Dictionary = {}   # peer_id → { window_start_ms: int, count: int }

# Generic per-(peer, kind) rate state for everything-but-chat. Keyed by
# String "peer:kind" so we don't double-charge a peer who fires at 10/s and
# also opens chests at 1/s. Each entry: { window_start_ms, count }.
var _rpc_rate_state: Dictionary = {}

# Rate budgets for each gated RPC. Tuned per-RPC because they have very
# different "legitimate" rates — autofire is ~10/s, create_room is ~once/min.
# Format: kind → [burst, window_ms]. Burst is the count threshold AFTER
# which further hits in the same window are dropped.
const _RPC_RATE_BUDGETS := {
	"fire":      [30, 1000],   # autofire ~10/s × 3x headroom
	"ability":   [4, 1000],    # taps; ability cooldown >1s anyway
	"create":    [3, 5000],    # room create is heavy (broadcasts to whole DS)
	"profile":   [6, 2000],    # lobby name/skin edits
	"ready":     [10, 2000],   # toggling ready, indecisive but bounded
	"upgrade":   [10, 2000],   # shop upgrade clicks
	"bind":      [3, 5000],    # request_profile creates DB rows on first contact — keep low
}


# R4: called from GameController._on_peer_disconnected_as_host. Without this,
# (a) the dicts grow by one entry per ever-connected peer for the DS process
# lifetime, and (b) peer-id reuse (Godot's IDs are 32-bit random; collisions
# rare but possible across reconnects) would let a new connection inherit
# the old occupant's saturated budgets and get silently throttled on their
# first message.
func forget_peer(peer: int) -> void:
	_chat_rate_state.erase(peer)
	# Generic budgets keyed by "peer:kind". Sweep the whole dict — there
	# are at most |kinds| entries per peer so this is O(kinds).
	for k in _RPC_RATE_BUDGETS.keys():
		_rpc_rate_state.erase("%d:%s" % [peer, k])


# Returns true if the (peer, kind) hit is within budget; false if it should
# be dropped. Server-side only — on a client the check no-ops (RPCs are
# `call_remote`, so a client's call goes to the server which gates there).
# Self-contained: maintains its own state, callers just yes/no.
func _check_rpc_rate(peer: int, kind: String) -> bool:
	if not multiplayer.is_server():
		return true
	var budget: Variant = _RPC_RATE_BUDGETS.get(kind)
	if budget == null:
		return true   # unknown kind → don't gate (better than silently dropping)
	var burst: int = int(budget[0])
	var window_ms: int = int(budget[1])
	var now_ms: int = Time.get_ticks_msec()
	var key: String = "%d:%s" % [peer, kind]
	var s: Dictionary = _rpc_rate_state.get(key, {"window_start_ms": now_ms, "count": 0})
	if now_ms - int(s.get("window_start_ms", 0)) > window_ms:
		s = {"window_start_ms": now_ms, "count": 0}
	s["count"] = int(s.get("count", 0)) + 1
	_rpc_rate_state[key] = s
	return int(s["count"]) <= burst


@rpc("any_peer", "reliable", "call_remote")
func client_chat_line(text: String, color: Color) -> void:
	var peer := multiplayer.get_remote_sender_id()
	# Per-peer rate limit (server-side only — clients calling this on themselves
	# is fine since call_remote excludes self anyway). On the server, check the
	# sender's budget before emitting; on a client receiving this RPC (which
	# can't happen — `call_remote` routes only to remote peers, i.e. to the
	# server when called from a client) we'd still want the same gate, so the
	# check is unconditional.
	if multiplayer.is_server():
		var now_ms: int = Time.get_ticks_msec()
		var s: Dictionary = _chat_rate_state.get(peer, {"window_start_ms": now_ms, "count": 0})
		if now_ms - int(s.get("window_start_ms", 0)) > CHAT_WINDOW_MS:
			s = {"window_start_ms": now_ms, "count": 0}
		s["count"] = int(s.get("count", 0)) + 1
		_chat_rate_state[peer] = s
		if int(s["count"]) > CHAT_BURST:
			return   # spam — silently drop
		# Cap length to defend the reliable broadcast channel from megabyte payloads.
		if text.length() > CHAT_MAX_LEN:
			text = text.substr(0, CHAT_MAX_LEN)
	client_chat_received.emit(peer, text, color)


# ── server → client ──────────────────────────────────────────────────────
@rpc("authority", "reliable", "call_remote")
func server_welcome(your_peer: int, server_tick: int) -> void:
	server_welcome_received.emit(your_peer, server_tick)


@rpc("authority", "unreliable_ordered", "call_remote")
func server_send_snapshot(tick: int, entities: Array) -> void:
	server_snapshot_received.emit(tick, entities)


# ── Latency probe ───────────────────────────────────────────────────────────
# Client sends its local timestamp; server echoes it straight back to that peer
# so the client can compute round-trip time. Client throttles, so no rate-gate.
signal server_pong_received(client_time_ms: int)

@rpc("any_peer", "unreliable", "call_remote")
func client_ping(client_time_ms: int) -> void:
	var peer: int = multiplayer.get_remote_sender_id()
	server_pong.rpc_id(peer, client_time_ms)

@rpc("authority", "unreliable", "call_remote")
func server_pong(client_time_ms: int) -> void:
	server_pong_received.emit(client_time_ms)


@rpc("authority", "reliable", "call_remote")
func server_apply_damage(target: int, new_hp: float, src: int, weapon: StringName, headshot: bool) -> void:
	server_damage_received.emit(target, new_hp, src, weapon, headshot)


@rpc("authority", "reliable", "call_remote")
func server_chat_line(peer: int, text: String, color: Color) -> void:
	server_chat_received.emit(peer, text, color)


# DS-M3: sent right after welcome so the client knows whether to drive itself
# locally (listen-host) or to defer all simulation to the server (dedicated).
@rpc("authority", "reliable", "call_remote")
func server_mode_info(is_dedicated: bool) -> void:
	server_mode_info_received.emit(is_dedicated)


# Server-authoritative map sync. Sent during sync_request before spawn RPCs
# so the client can free its locally-picked map (the menu's MAP picker is
# host-only) and load the server's choice before player positions arrive.
@rpc("authority", "reliable", "call_remote")
func server_map_info(map_path: String) -> void:
	server_map_info_received.emit(map_path)


# R11: server-authoritative mode sync. Same lifecycle as server_map_info —
# sent during sync_request alongside the map. Pass empty string to mean
# "casual / no mode_def" (practice path).
@rpc("authority", "reliable", "call_remote")
func server_mode_def(mode_path: String) -> void:
	server_mode_def_received.emit(mode_path)


# Throwable lifecycle broadcasts. spawn = "start drawing a projectile at
# `origin` with `velocity` and run physics locally". explode = "stop the
# projectile and play VFX at `position`". Reliable so a dropped spawn
# doesn't leave the client with a phantom mesh.
@rpc("authority", "reliable", "call_remote")
func server_throwable_spawn(proj_id: int, weapon_id: StringName, origin: Vector3, velocity: Vector3) -> void:
	server_throwable_spawn_received.emit(proj_id, weapon_id, origin, velocity)


@rpc("authority", "reliable", "call_remote")
func server_throwable_explode(proj_id: int, position: Vector3) -> void:
	server_throwable_explode_received.emit(proj_id, position)


# Staging "host clicked START" broadcast. Fired from main_menu's staging
# panel; every joined client transitions from "waiting in lobby" to
# "loading game scene".
@rpc("authority", "reliable", "call_remote")
func server_match_starting() -> void:
	server_match_starting_received.emit()


# Server tells the requester why their client_start_match was rejected,
# so the UI can re-enable the button and show "you're not the host" /
# "room no longer exists" instead of silently freezing.
@rpc("authority", "reliable", "call_remote")
func server_start_match_failed(reason: String) -> void:
	server_start_match_failed_received.emit(reason)


# ── Lobby/room RPCs (server → client). RoomManager calls these via rpc_id
#    to scope the audience: server_room_list to the requester, server_room_state
#    to all room members, server_room_destroyed to the evicted set.
@rpc("authority", "reliable", "call_remote")
func server_room_list(rooms: Array) -> void:
	server_room_list_received.emit(rooms)


@rpc("authority", "reliable", "call_remote")
func server_room_joined(room_id: String, room_state: Dictionary) -> void:
	server_room_joined_received.emit(room_id, room_state)


@rpc("authority", "reliable", "call_remote")
func server_room_join_failed(reason: String) -> void:
	server_room_join_failed_received.emit(reason)


@rpc("authority", "reliable", "call_remote")
func server_room_state(room_state: Dictionary) -> void:
	server_room_state_received.emit(room_state)


@rpc("authority", "reliable", "call_remote")
func server_room_destroyed(room_id: String) -> void:
	server_room_destroyed_received.emit(room_id)


@rpc("authority", "reliable", "call_remote")
func server_match_ended(room_state: Dictionary) -> void:
	server_match_ended_received.emit(room_state)


@rpc("authority", "reliable", "call_remote")
func server_score_update(rows: Array) -> void:
	server_score_update_received.emit(rows)


# ── Persistence broadcasts (server → one specific client) ───────────────

@rpc("authority", "reliable", "call_remote")
func server_profile(profile: Dictionary) -> void:
	server_profile_received.emit(profile)


@rpc("authority", "reliable", "call_remote")
func server_action_result(action: String, ok: bool, reason: String) -> void:
	server_action_result_received.emit(action, ok, reason)


@rpc("authority", "reliable", "call_remote")
func server_leaderboard(rows: Array) -> void:
	server_leaderboard_received.emit(rows)


@rpc("authority", "reliable", "call_remote")
func server_reward(kind: String, reward: Dictionary) -> void:
	server_reward_received.emit(kind, reward)


# DS-M5: server-driven respawn announcement. Sent to all clients so they can
# reset their view of the player (move + show + restore HP).
@rpc("authority", "reliable", "call_remote")
func server_player_respawned(peer: int, pos: Vector3) -> void:
	server_respawn_received.emit(peer, pos)


# C6: server-driven death announcement. Sent right after server_apply_damage
# whenever HP drops to ≤0 on the server. Single source of truth for death,
# carries the killer so clients can attribute kill feed correctly.
@rpc("authority", "reliable", "call_remote")
func server_player_died(victim_peer: int, killer_peer: int, weapon: StringName, headshot: bool) -> void:
	server_death_received.emit(victim_peer, killer_peer, weapon, headshot)
