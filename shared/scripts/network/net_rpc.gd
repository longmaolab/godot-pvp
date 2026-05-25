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
signal client_chat_received(peer_id: int, text: String, color: Color)

# ── Lobby/room RPCs (Phase 1 — see .agent/lobby_plan.md). All client→server,
#    handled by RoomManager autoload which gates on is_server() and talks
#    back through the server→client RPCs below.
signal client_list_rooms_received(peer_id: int)
signal client_create_room_received(peer_id: int, map_path: String, mode_def_path: String)
signal client_join_room_received(peer_id: int, room_id: String)
signal client_leave_room_received(peer_id: int)
signal client_start_match_received(peer_id: int)

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
## Host clicked START in the menu's staging area; all clients should leave
## the lobby state and load the game scene now. The host's map/mode picks
## are already authoritative via _launch_game → server_map_info during
## sync_request, so this RPC carries no payload — it's just "go".
signal server_match_starting_received()

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
	client_fire_received.emit(peer, weapon_id, yaw, pitch)


@rpc("any_peer", "reliable", "call_remote")
func client_use_ability() -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_ability_received.emit(peer)


# ── Lobby/room RPCs (client → server). All are dumb relays — RoomManager
#    listens on the signals above and does the actual logic.
@rpc("any_peer", "reliable", "call_remote")
func client_list_rooms() -> void:
	var peer := multiplayer.get_remote_sender_id()
	client_list_rooms_received.emit(peer)


@rpc("any_peer", "reliable", "call_remote")
func client_create_room(map_path: String, mode_def_path: String) -> void:
	var peer := multiplayer.get_remote_sender_id()
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


# Per-peer chat throttle. Allow CHAT_BURST messages within CHAT_WINDOW_MS,
# then silently drop until the window slides. Keeps a single peer from
# flooding all clients via the reliable broadcast path.
const CHAT_MAX_LEN := 240
const CHAT_BURST := 5
const CHAT_WINDOW_MS := 4000
var _chat_rate_state: Dictionary = {}   # peer_id → { window_start_ms: int, count: int }


# R4: called from GameController._on_peer_disconnected_as_host. Without this,
# (a) the dict grows by one entry per ever-connected peer for the DS process
# lifetime, and (b) peer-id reuse (Godot's IDs are 32-bit random; collisions
# rare but possible across reconnects) would let a new connection inherit
# the old occupant's saturated chat budget and get silently muted on their
# first message.
func forget_peer(peer: int) -> void:
	_chat_rate_state.erase(peer)


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


# Staging "host clicked START" broadcast. Fired from main_menu's staging
# panel; every joined client transitions from "waiting in lobby" to
# "loading game scene".
@rpc("authority", "reliable", "call_remote")
func server_match_starting() -> void:
	server_match_starting_received.emit()


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
