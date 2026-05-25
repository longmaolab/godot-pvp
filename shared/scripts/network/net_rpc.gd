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
signal client_chat_received(peer_id: int, text: String, color: Color)

# ── client-side signals (fired when an RPC arrives from the server) ──────
signal server_welcome_received(your_peer: int, server_tick: int)
signal server_snapshot_received(tick: int, entities: Array)
signal server_damage_received(target: int, new_hp: float, src: int, weapon: StringName, headshot: bool)
signal server_chat_received(peer: int, text: String, color: Color)
# DS-M3: server tells the client what kind of host it is right after welcome
# (true = dedicated → client must send input + render from snapshot only).
signal server_mode_info_received(is_dedicated: bool)
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


# Per-peer chat throttle. Allow CHAT_BURST messages within CHAT_WINDOW_MS,
# then silently drop until the window slides. Keeps a single peer from
# flooding all clients via the reliable broadcast path.
const CHAT_MAX_LEN := 240
const CHAT_BURST := 5
const CHAT_WINDOW_MS := 4000
var _chat_rate_state: Dictionary = {}   # peer_id → { window_start_ms: int, count: int }


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
