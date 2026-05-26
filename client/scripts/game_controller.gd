extends Node3D
class_name GameController
## Hosts a single playable scene.
##
## Three runtime modes:
##   1. PRACTICE (no multiplayer peer)   — spawn local player + stationary dummy.
##   2. HOST (multiplayer + is_server)   — spawn local player + spawn one for
##      every connecting peer; broadcast spawn RPC so clients mirror.
##   3. CLIENT (multiplayer + !is_server)— spawn local player; wait for server
##      to send spawn RPCs for the host and other peers.

const PLAYER_SCENE := preload("res://shared/scenes/player.tscn")
const BOT_SCENE := preload("res://shared/scenes/bot.tscn")
const DUMMY_SCENE := preload("res://shared/scenes/dummy_target.tscn")
const AK20: Resource = preload("res://shared/data/weapons/ak20.tres")
const SG8: Resource = preload("res://shared/data/weapons/sg8.tres")
const SRX: Resource = preload("res://shared/data/weapons/srx.tres")
const RAILGUN: Resource = preload("res://shared/data/weapons/railgun.tres")
const CROSSBOW: Resource = preload("res://shared/data/weapons/crossbow.tres")
const DEFAULT_LOADOUT: Array[Resource] = [AK20, SG8, SRX, RAILGUN]

const _WEAPON_REGISTRY := preload("res://shared/scripts/weapon_registry.gd")
var weapon_registry: Node

@export var map_scene: PackedScene = preload("res://shared/scenes/maps/blank.tscn")
@export var hud_scene: PackedScene = preload("res://client/scenes/hud/hud.tscn")
@export var spawn_dummy: bool = true
@export var spawn_bot_in_practice: bool = true
@export var mode_def: Resource = null            # ModeDef; null means casual practice
@export var lag_compensation_enabled: bool = true
@export var default_lag_comp_ping_ms: float = 60.0
# DS-M1: set true when launched as a dedicated server (godot --server). The
# server has no local human — no HUD, no local player, no overlays, no input.
# Only the authority side of multiplayer runs.
@export var is_dedicated_server: bool = false

# UI overlay scenes mounted in _ready alongside HUD.
const PAUSE_SCENE := preload("res://client/scenes/hud/pause_menu.tscn")
const MATCH_END_SCENE := preload("res://client/scenes/hud/match_end.tscn")
const CONNECTING_SCENE := preload("res://client/scenes/hud/connecting_overlay.tscn")
const COMMS_WHEEL_SCENE := preload("res://client/scenes/hud/comms_wheel.tscn")
const ADMIN_PANEL_SCENE := preload("res://client/scenes/hud/admin_panel.tscn")

var pause_menu: Node = null
var connecting_overlay: Node = null
var comms_wheel: Node = null
var admin_panel: Node = null

var local_player: PlayerController
var hud: HUD
var dummy: DummyTarget
var map_root: Node3D
var players_by_peer: Dictionary = {}              # peer_id → PlayerController
var bots: Array[Node] = []
var match_controller: Node = null                 # MatchController
var lag_comp: Node = null                         # LagCompensator (host only)
# F3-M1: per-room World3D containers. Keyed by room_id. Populated by
# _boot_match_for_room when a room flips to MATCH state; entries freed
# by _tear_down_match_world (or when the parent room is destroyed).
# Empty in practice mode (practice doesn't use rooms). M1 only creates
# the container — map/players still live on GameController until M3.
const _ROOM_WORLD_SCRIPT := preload("res://server/scripts/room_world.gd")
var room_worlds: Dictionary = {}                  # room_id (String) → RoomWorld

# Peers whose game scene is confirmed loaded and ready to receive RPCs.
# Server-only state. Empty on clients. Host is added immediately at boot;
# clients are added when their _rpc_sync_request lands.
var _ready_peers: Array[int] = []

# C2: peers that have already issued _rpc_sync_request. Used to make the
# sync handler idempotent — a peer that re-requests inside the cooldown
# window is rejected rather than triggering a full re-spawn broadcast.
var _synced_peers: Dictionary = {}   # peer_id → last_sync_ms (int)

# H2: one outstanding respawn timer per peer. If the peer dies twice quickly
# (e.g. takes damage during the down-state, or a stale RPC arrives) we cancel
# the prior timer and replace it — otherwise we'd schedule N respawns and the
# last to fire wins, potentially overwriting HP/position mid-game.
var _pending_respawn: Dictionary = {}   # peer_id → SceneTreeTimer

# H5: last applied snapshot tick. Unreliable_ordered guarantees in-channel
# ordering but a late packet can still arrive after a fresh one is applied,
# so we monotonically gate the consumer.
var _last_snapshot_tick: int = -1

@onready var players_root: Node3D = Node3D.new()


func _ready() -> void:
	# Build weapon registry first so it's ready before any spawn/fire.
	weapon_registry = _WEAPON_REGISTRY.new()
	add_child(weapon_registry)

	# Map + Players root are needed on both server and client.
	map_root = map_scene.instantiate()
	add_child(map_root)
	players_root.name = "Players"
	add_child(players_root)

	# Client-only UI: HUD, pause menu, overlays, comms wheel, admin panel.
	# A dedicated server (--server) has no local human, so skip everything
	# that draws or reads input.
	if not is_dedicated_server:
		hud = hud_scene.instantiate()
		add_child(hud)

		# Pause overlay (Esc) — runs even when SceneTree is paused (process_mode=3).
		pause_menu = PAUSE_SCENE.instantiate()
		add_child(pause_menu)

		# Connecting overlay — shown only on clients while waiting for spawn data.
		connecting_overlay = CONNECTING_SCENE.instantiate()
		add_child(connecting_overlay)

		# Comms wheel (Z = tactical / X = social), always available in-match.
		comms_wheel = COMMS_WHEEL_SCENE.instantiate()
		add_child(comms_wheel)

		# Admin / cheat panel — toggled with F2.
		admin_panel = ADMIN_PANEL_SCENE.instantiate()
		add_child(admin_panel)

	# Match controller — spun up if a mode_def is assigned. Runs on both
	# dedicated server (authoritative) and listen-host.
	if mode_def != null:
		var mc_script := load("res://shared/scripts/match_controller.gd")
		match_controller = mc_script.new()
		match_controller.mode_def = mode_def
		add_child(match_controller)
		match_controller.match_ended.connect(_on_match_ended)
		match_controller.round_ended.connect(_on_round_ended)
		match_controller.start()

	if is_dedicated_server:
		_enter_dedicated_server_mode()
	elif not _is_networked():
		_enter_practice_mode()
	else:
		# Damage broadcast handler is the same on host and client.
		# (R7: server_death_received is NOT wired here — _on_server_player_died's
		# first line is `if multiplayer.is_server(): return`, so connecting it on
		# the host side is a no-op. _enter_client_mode() wires it for clients
		# only, where it has actual work to do.)
		var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
		if net_rpc != null:
			net_rpc.server_damage_received.connect(_on_server_damage_broadcast)
		if multiplayer.is_server():
			_enter_host_mode()
		else:
			_enter_client_mode()


# ── DEDICATED SERVER ───────────────────────────────────────────────────────
## DS-M1: server has no local player and no HUD. Just hold the world and
## accept peer connections. Subsequent milestones (M2-M5) will add input
## handling + snapshot broadcast + authoritative simulation here.
func _enter_dedicated_server_mode() -> void:
	print("[GameController] dedicated server world ready")
	# DS-M4: stand up the lag-compensator so the snapshot tick recorder + fire
	# rewind work identically to listen-host. Without this, fire raycasts use
	# CURRENT target positions which is wrong under any non-zero ping.
	var lc_script := load("res://server/scripts/lag_compensator.gd")
	if lc_script != null:
		lag_comp = lc_script.new()
		add_child(lag_comp)
	# DS-M4 test hook: with --dummy, spawn a stationary DummyTarget the clients
	# can shoot at to prove server-authoritative hits.
	if spawn_dummy:
		dummy = DUMMY_SCENE.instantiate()
		add_child(dummy)
		var marker: Node3D = map_root.get_node_or_null(^"DummySpawn")
		dummy.global_position = marker.global_position if marker != null else Vector3(0, 0, -10)
		dummy.damaged.connect(_on_dummy_damaged_ds)
		dummy.downed.connect(_on_dummy_downed_ds)
		print("[server] dummy target spawned at %s" % str(dummy.global_position))
	# Hook the same peer_connected/disconnected machinery the listen-host uses.
	# When clients connect, server spawns a PlayerController for them.
	if not multiplayer.peer_connected.is_connected(_on_peer_connected_as_host):
		multiplayer.peer_connected.connect(_on_peer_connected_as_host)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected_as_host):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected_as_host)
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		# Damage broadcast — server hits trigger broadcasts to all clients.
		if not net_rpc.server_damage_received.is_connected(_on_server_damage_broadcast):
			net_rpc.server_damage_received.connect(_on_server_damage_broadcast)
		# Hello handshake — moved here from MatchAuthority so dedicated server
		# doesn't need that stub running alongside.
		if not net_rpc.client_hello_received.is_connected(_on_client_hello_ds):
			net_rpc.client_hello_received.connect(_on_client_hello_ds)
		# Fire path: clients send fire intents via client_fire, server resolves.
		if not net_rpc.client_fire_received.is_connected(_on_client_fire_server):
			net_rpc.client_fire_received.connect(_on_client_fire_server)
		# Ability mirror: listen-host clients also send this so the server's
		# view picks up buff/powershot state; DS path is double-covered (the
		# INPUT_ABILITY edge in push_remote_input also triggers it).
		if not net_rpc.client_ability_received.is_connected(_on_client_ability_server):
			net_rpc.client_ability_received.connect(_on_client_ability_server)
		# DS-M2: per-tick input RPCs from clients → routed to the corresponding
		# server-side PlayerController. The player simulates physics with this
		# input instead of reading Input.* (which is meaningless on the server).
		if not net_rpc.client_input_received.is_connected(_on_client_input_ds):
			net_rpc.client_input_received.connect(_on_client_input_ds)
	# Lobby M2: RoomManager fires match_started when a room's host clicks
	# START — boot the match world here for that room's players. M3:
	# match_finished + room_destroyed are the cleanup signals — both can
	# end the active match (the former from match_controller's win
	# condition, the latter from host disconnect mid-match). Both routes
	# converge on _tear_down_match_world.
	var room_mgr: Node = get_node_or_null(^"/root/RoomManager")
	if room_mgr != null:
		if not room_mgr.match_started.is_connected(_boot_match_for_room):
			room_mgr.match_started.connect(_boot_match_for_room)
		if not room_mgr.match_finished.is_connected(_on_match_finished_in_room):
			room_mgr.match_finished.connect(_on_match_finished_in_room)
		if not room_mgr.room_destroyed.is_connected(_on_room_destroyed_check_active):
			room_mgr.room_destroyed.connect(_on_room_destroyed_check_active)


## DS-M1 hello handshake. When a client sends client_hello, reply with
## server_welcome so the client knows the server side is alive. DS-M3: also
## send server_mode_info so the client switches to "render from snapshot"
## mode instead of locally simulating.
func _on_client_hello_ds(peer_id: int, username: String) -> void:
	print("[server] hello from peer %d (%s)" % [peer_id, username])
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.server_welcome.rpc_id(peer_id, peer_id, _snapshot_tick)
		net_rpc.server_mode_info.rpc_id(peer_id, true)


## DS-M2: route a client's input frame to its server-side player. Discards
## input from unknown / unspawned peers (e.g., a client that hasn't completed
## handshake yet) silently — they'll be reaped on disconnect.
func _on_client_input_ds(peer_id: int, tick: int, bits: int, yaw: float, pitch: float) -> void:
	var p: Node = players_by_peer.get(peer_id)
	if p == null or not is_instance_valid(p):
		return
	if not p.has_method(&"push_remote_input"):
		return
	p.push_remote_input(tick, bits, yaw, pitch)


# DS-M3: snapshot broadcast state. The server packs the world's player states
# every NET_SYNC_INTERVAL and broadcasts to all connected clients.
const _SNAPSHOT_INTERVAL: float = 1.0 / 30.0
var _snapshot_accum: float = 0.0
var _snapshot_tick: int = 0


## DS-M3 + lag-comp recording: one consolidated physics-tick body. Runs on
## both listen-host (lag_comp.record) and dedicated server (snapshot broadcast).
func _physics_process(delta: float) -> void:
	# Lag-comp position history (host + DS). Used by DS-M4 for rewind raycasts.
	if multiplayer.is_server() and lag_comp != null:
		for peer in players_by_peer.keys():
			var p: Node = players_by_peer[peer]
			if p == null or not is_instance_valid(p):
				continue
			lag_comp.record(peer, p.global_position, p.rotation.y, p.head.rotation.x)
	# DS snapshot broadcast — only the dedicated server emits these. Listen-host
	# clients still drive each other via the legacy _net_apply_state path.
	if not is_dedicated_server:
		return
	_snapshot_accum += delta
	if _snapshot_accum < _SNAPSHOT_INTERVAL:
		return
	_snapshot_accum = 0.0
	_snapshot_tick += 1
	if players_by_peer.is_empty():
		return
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		return
	# F3-M3c: snapshot scoping. If any rooms exist server-side, send
	# each room only its own players' positions — otherwise concurrent
	# matches would see each other on the radar and through walls. The
	# `else` branch keeps the legacy global broadcast for the MP
	# integration tests (mp_game_test, fire_test, ...) that connect
	# directly to the DS without going through the lobby system.
	var rm: Node = get_node_or_null(^"/root/RoomManager")
	# Direct property access — see _room_id_for_peer's comment for why
	# `rm.get("rooms")` doesn't work but `rm.rooms` does.
	var rooms_dict: Dictionary = rm.rooms if rm != null else {}
	if not rooms_dict.is_empty():
		var live: Array = multiplayer.get_peers()
		for rid in rooms_dict.keys():
			var room: Variant = rooms_dict[rid]
			if room == null:
				continue
			var room_peers: Array = room.players
			var entities_r: Array = _build_snapshot_entities(room_peers)
			# Empty entities = no players in this room → skip the RPC
			# (saves a no-op packet per tick per empty room).
			if entities_r.is_empty():
				continue
			for peer in room_peers:
				if peer in live:
					net_rpc.server_send_snapshot.rpc_id(peer, _snapshot_tick, entities_r)
	else:
		# Broadcast to every client. unreliable_ordered: snapshots are idempotent
		# (latest wins), don't retransmit drops.
		var entities: Array = _build_snapshot_entities(players_by_peer.keys())
		net_rpc.server_send_snapshot.rpc(_snapshot_tick, entities)


## F3-M3c: snapshot entity-builder. Pulled out of the per-tick path so
## both the per-room and legacy-global broadcasts use one source of
## truth for what a "snapshot entry" looks like.
func _build_snapshot_entities(peer_ids) -> Array:
	var entities: Array = []
	for peer_id in peer_ids:
		if not players_by_peer.has(peer_id):
			continue
		var p: Node = players_by_peer[peer_id]
		if p == null or not is_instance_valid(p):
			continue
		var flags: int = 0
		if "is_dead" in p and p.is_dead:
			flags |= NetProtocol.ENTITY_FLAG_DEAD
		if "is_reloading" in p and p.is_reloading:
			flags |= NetProtocol.ENTITY_FLAG_RELOADING
		# No mag/res: server doesn't track per-weapon ammo, and pushing its
		# (stale) ammo down to the client overwrites whatever weapon the
		# client locally switched to. See _on_server_snapshot for context.
		entities.append({
			"p":     peer_id,
			"pos":   p.global_position,
			"yaw":   p.rotation.y,
			"pitch": p.head.rotation.x if "head" in p else 0.0,
			"hp":    int(p.hp) if "hp" in p else 0,
			"flags": flags,
		})
	return entities


func _is_networked() -> bool:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null:
		return false
	return not (peer is OfflineMultiplayerPeer)


# ── PRACTICE ───────────────────────────────────────────────────────────────
func _enter_practice_mode() -> void:
	# Practice mode uses a synthetic peer id of 1 (matches Godot's "server peer
	# id" sentinel — harmless since no networking is active).
	_local_spawn(1, _spawn_pos_for(1))
	dummy = DUMMY_SCENE.instantiate()
	add_child(dummy)
	var marker: Node3D = map_root.get_node_or_null(^"DummySpawn")
	dummy.global_position = marker.global_position if marker != null else Vector3(0, 0, -10)
	dummy.damaged.connect(_on_dummy_damaged)
	dummy.downed.connect(_on_dummy_downed)
	# Practice mode: spawn the bot far away with NO target for 5s, so the kid
	# has time to find WASD, look around, and check the weapon. Then it
	# wakes up and pursues — at a more forgiving speed than MP bots.
	if local_player != null:
		# Spawn bot 10m in front of the player so it's immediately visible.
		var fwd: Vector3 = -local_player.global_transform.basis.z
		fwd.y = 0
		if fwd.length_squared() < 0.001:
			fwd = Vector3(0, 0, -1)
		fwd = fwd.normalized()
		var bot_pos: Vector3 = local_player.global_position + fwd * 10.0
		bot_pos.y = 1.0
		var bot: Node = spawn_bot(null, bot_pos, AK20)
		if hud != null:
			hud.push_feed("BOT 在你前方 — 5 秒后开始追击", Color(1, 0.85, 0.5))
		get_tree().create_timer(5.0).timeout.connect(
			func():
				if not is_instance_valid(bot) or not is_instance_valid(local_player):
					return
				bot.target = local_player
				bot.pursue_speed = 3.2
				bot.attack_range = 22.0
				if hud != null:
					hud.push_feed("BOT 在追你！", Color(1, 0.5, 0.4))
		)
func spawn_bot(target: Node, at: Vector3, weapon: Resource) -> Node:
	var bot: Node = BOT_SCENE.instantiate()
	bot.weapon_def = weapon
	bot.target = target
	bot.player_name = "Bot"
	add_child(bot)
	bot.global_position = at
	bot.head_hitbox.monitoring = true
	bot.body_hitbox.monitoring = true
	bots.append(bot)
	# Bots auto-respawn so practice mode keeps having a punching bag/target.
	bot.died.connect(func(_killer):
		if is_instance_valid(bot):
			_on_bot_died(bot, at)
	)
	return bot


func _on_bot_died(bot: Node, original_spawn: Vector3) -> void:
	if hud != null:
		hud.push_feed("BOT DOWN — respawn in 5s", Color(0.7, 1, 0.5))
	get_tree().create_timer(5.0).timeout.connect(func():
		if not is_instance_valid(bot):
			return
		bot.respawn(original_spawn)
		if hud != null:
			hud.push_feed("bot respawned", Color(1, 0.6, 0.4))
	)


# ── HOST (listen-server) ───────────────────────────────────────────────────
func _enter_host_mode() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected_as_host)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected_as_host)
	# Server-authoritative damage: every fire from any peer comes through here.
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.client_fire_received.connect(_on_client_fire_server)
		net_rpc.client_ability_received.connect(_on_client_ability_server)
		# Listen-host movement authority: remote peers now stream input bits to the
		# host as well, so the host simulates their CharacterBody3D through real
		# collision instead of accepting raw transform pushes.
		net_rpc.client_input_received.connect(_on_client_input_ds)
	# Stand up the lag-compensator so the host accumulates position history
	# starting from match start.
	var lc_script := load("res://server/scripts/lag_compensator.gd")
	lag_comp = lc_script.new()
	add_child(lag_comp)
	# Spawn self (host is always "ready" — its scene is right here).
	var my_id: int = multiplayer.get_unique_id()
	_ready_peers.append(my_id)
	_local_spawn(my_id, _spawn_pos_for(my_id))
	# Race protection: any peer that connected before this controller's _ready
	# fired needs to be picked up retroactively.
	for already_connected in multiplayer.get_peers():
		if not players_by_peer.has(already_connected):
			_on_peer_connected_as_host(already_connected)
	hud.push_feed("HOSTING on :7777", Color(0.4, 0.9, 1.0))


func _on_peer_connected_as_host(new_peer: int) -> void:
	# Do NOT push spawn RPCs to the new peer yet — their game scene isn't
	# mounted. They'll request a sync via _rpc_sync_request once ready.
	# Only inform already-ready peers about the new arrival, and instantiate
	# the new player locally on the host.
	var pos: Vector3 = _spawn_pos_for(new_peer)
	# F3 fix: when the room system is active, scope the spawn broadcast.
	# Without this, a new peer connecting in lobby (no room yet) gets
	# broadcast to every in-game peer regardless of room — causing
	# "ghost" players to appear in unrelated rooms' matches. The new
	# peer's eventual room-mates will see them via the inverse loop in
	# _rpc_sync_request when they enter the match together.
	var rm: Node = get_node_or_null(^"/root/RoomManager")
	var have_rooms: bool = rm != null and not rm.rooms.is_empty()
	if have_rooms:
		var new_peer_room: String = _room_id_for_peer(new_peer)
		# Lobbyists (not in any room) shouldn't appear in any running
		# match. Skip the broadcast entirely — same-room visibility is
		# established later via sync_request when they actually enter
		# a match together.
		if not new_peer_room.is_empty():
			var prof: Dictionary = _profile_for_peer(new_peer)
			for peer in _ready_peers:
				if peer == multiplayer.get_unique_id() or peer == new_peer:
					continue
				if _room_id_for_peer(peer) == new_peer_room:
					_rpc_spawn.rpc_id(peer, new_peer, pos, prof.name, prof.skin)
	else:
		# Legacy single-shared-world (tests, pre-lobby setups): broadcast
		# to every ready peer like before. No profile available — let the
		# remote default ("P%d") render.
		for peer in _ready_peers:
			if peer != multiplayer.get_unique_id() and peer != new_peer:
				_rpc_spawn.rpc_id(peer, new_peer, pos)
	_local_spawn(new_peer, pos)


func _on_peer_disconnected_as_host(peer: int) -> void:
	_ready_peers.erase(peer)
	# H2: drop any pending respawn — peer is gone, there's nothing to respawn.
	# The SceneTreeTimer fires once and we can't preempt it, but clearing the
	# dict entry means _ds_respawn_player's `victim == null` early-return is
	# the only side effect when it eventually fires.
	_pending_respawn.erase(peer)
	# F3 fix: snapshot the leaver's room BEFORE leave_room nukes the
	# peer_to_room mapping. Used below to scope the despawn broadcast.
	var leaver_room: String = _room_id_for_peer(peer)
	# Lobby M2 cleanup: tell RoomManager the peer is gone so room state
	# doesn't stay stuck (without this, a player who closes the browser
	# tab mid-match leaves their room in MATCH state forever).
	var room_mgr: Node = get_node_or_null(^"/root/RoomManager")
	if room_mgr != null and is_dedicated_server:
		room_mgr.leave_room(peer)
	# C2 + R4: free per-peer rate-limit state so the dict doesn't grow
	# unboundedly across connect/disconnect cycles, AND so a recycled
	# peer-id doesn't inherit the previous occupant's chat quota.
	_synced_peers.erase(peer)
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null and net_rpc.has_method(&"forget_peer"):
		net_rpc.forget_peer(peer)
	# Only despawn-broadcast to peers who actually have a /root/Game node
	# loaded — anyone in main_menu / room_browser / room_lobby just gets a
	# "Node not found: Game" engine error and 5 lines of stack trace from
	# trying to route an RPC to a path that doesn't exist on their side.
	# _ready_peers is the set of peers who sent _rpc_sync_request, which
	# only happens after game.tscn loads.
	#
	# F3 fix: scope by room — leavers from room A shouldn't cause room B's
	# clients to despawn anybody. Legacy fallback for when no rooms exist.
	var rm: Node = get_node_or_null(^"/root/RoomManager")
	var have_rooms: bool = rm != null and not rm.rooms.is_empty()
	for ready_peer in _ready_peers:
		if ready_peer == peer:
			continue
		if have_rooms and not leaver_room.is_empty():
			if _room_id_for_peer(ready_peer) != leaver_room:
				continue
		_rpc_despawn.rpc_id(ready_peer, peer)
	_despawn(peer)


func get_ready_peers() -> Array[int]:
	return _ready_peers


# ── CLIENT ─────────────────────────────────────────────────────────────────
## True when the connected server is a dedicated server (vs listen-host). Set
## by server_mode_info. Determines how the local player synchronizes.
var _server_is_dedicated: bool = false


func _enter_client_mode() -> void:
	if hud != null:
		hud.push_feed("CONNECTING...", Color(0.7, 0.85, 1.0))
	if connecting_overlay != null:
		var addr: String = "remote server"
		var peer := multiplayer.multiplayer_peer
		if peer != null and peer.has_method(&"get_url"):
			addr = String(peer.get_url())
		connecting_overlay.show_connecting(addr)
	# Surface connection failures immediately instead of waiting for timeout.
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)
	# DS-M3: subscribe to snapshot + mode_info BEFORE sending hello so we don't
	# miss a fast reply.
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		if not net_rpc.server_mode_info_received.is_connected(_on_server_mode_info):
			net_rpc.server_mode_info_received.connect(_on_server_mode_info)
		if not net_rpc.server_map_info_received.is_connected(_on_server_map_info):
			net_rpc.server_map_info_received.connect(_on_server_map_info)
		if not net_rpc.server_snapshot_received.is_connected(_on_server_snapshot):
			net_rpc.server_snapshot_received.connect(_on_server_snapshot)
		if not net_rpc.server_respawn_received.is_connected(_on_server_respawn):
			net_rpc.server_respawn_received.connect(_on_server_respawn)
		# C6: explicit death broadcast — single source of truth for kills.
		if not net_rpc.server_death_received.is_connected(_on_server_player_died):
			net_rpc.server_death_received.connect(_on_server_player_died)
		# Lobby M3: match end on a DS room → server pushes us back to
		# room_lobby with the latest room state in the payload.
		if not net_rpc.server_match_ended_received.is_connected(_on_server_match_ended):
			net_rpc.server_match_ended_received.connect(_on_server_match_ended)
	# WebSocket may still be CONNECTING right now — sending an RPC at this
	# moment would error "Trying to call an RPC via a multiplayer peer which
	# is not connected." Defer client_hello + _rpc_sync_request until the
	# connected_to_server signal fires (or fire immediately if already up).
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if multiplayer.multiplayer_peer != null \
			and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_on_connected_to_server()


## Fires (or is called directly) once the WebSocket handshake completes. At
## that point it's safe to send RPCs. Sends hello + sync_request.
func _on_connected_to_server() -> void:
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		return
	var name_str: String = "Player"
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		if "player_name" in s and not String(s.player_name).is_empty():
			name_str = s.player_name
	net_rpc.client_hello.rpc_id(1, name_str)
	# Ask the host to (re-)send every already-spawned player. Handles the race
	# where the host spawned players before the client's GameController existed.
	_rpc_sync_request.rpc_id(1)


## DS-M3: server tells us whether it's a dedicated server. If yes, our local
## player must stop simulating locally and switch to snapshot-rendered mode.
## Already-spawned players (ourselves) are upgraded in place.
func _on_server_mode_info(is_dedicated: bool) -> void:
	_server_is_dedicated = is_dedicated
	if not is_dedicated:
		return
	# Upgrade all existing players + every future spawn to snapshot-only mode.
	for peer_id in players_by_peer.keys():
		var p: Node = players_by_peer[peer_id]
		if p != null and is_instance_valid(p):
			_apply_ds_client_mode_to_player(p)


## Server is the source of truth for which map is loaded. Arrives during the
## sync_request handshake before any spawn RPC lands, so we have a window to
## free our local (menu-picked) map and load the server's. Idempotent on
## same-path messages; safe to fire multiple times.
func _on_server_map_info(map_path: String) -> void:
	if map_path.is_empty():
		return
	# Already on the requested map (host's local game already loaded it,
	# or a previous server_map_info already swapped us). No-op.
	var current_path: String = ""
	if map_root != null and map_root.scene_file_path != "":
		current_path = map_root.scene_file_path
	if current_path == map_path:
		return
	if not ResourceLoader.exists(map_path):
		push_warning("[client] server requested unknown map: %s — staying on %s" % [map_path, current_path])
		return
	var new_scene: PackedScene = load(map_path) as PackedScene
	if new_scene == null:
		push_warning("[client] failed to load server map: %s" % map_path)
		return
	# Out with the old map, in with the new. queue_free is deferred but the
	# replacement is added now — no frame where map_root is null + accessed.
	if map_root != null:
		map_root.queue_free()
	map_root = new_scene.instantiate()
	add_child(map_root)
	if hud != null:
		hud.push_feed("Loaded server map: %s" % map_path.get_file().get_basename(),
			Color(0.55, 0.85, 1, 1))


## M3: match for our room ended on the DS. The payload carries the room's
## state (back in LOBBY) so room_lobby can pick it up without a separate
## round-trip. An EMPTY room_state means the room was destroyed mid-match
## (host disconnected etc) — there's no lobby to go back to, so we route
## to the browser instead.
const ROOM_LOBBY_SCENE := "res://client/scenes/ui/room_lobby.tscn"
const ROOM_BROWSER_SCENE_CLIENT := "res://client/scenes/ui/room_browser.tscn"

func _on_server_match_ended(room_state: Dictionary) -> void:
	if room_state.is_empty():
		# Room is gone — bounce to browser.
		get_tree().change_scene_to_file(ROOM_BROWSER_SCENE_CLIENT)
		return
	# Hand off the room state via the Settings autoload — the lobby scene
	# reads `pending_room_state` in its _ready (same channel room_browser
	# uses on Create/Join). This is the only place this client receives
	# room_state during a match-ended transition because the game scene
	# doesn't subscribe to server_room_state_received.
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		if "pending_room_state" in s:
			s.pending_room_state = room_state.duplicate()
	get_tree().change_scene_to_file(ROOM_LOBBY_SCENE)


## Configure a player on a DS-client to render purely from snapshots. Local
## human additionally streams its input to the server each tick.
func _apply_ds_client_mode_to_player(p: Node) -> void:
	if not ("is_snapshot_only" in p):
		return
	p.is_snapshot_only = true
	# The local human needs an interpolator just like remote ghosts. Build it
	# late if _ready already finished without one (race-safe).
	if p.is_local and p.get_node_or_null(^"_input_send_helper") == null:
		var interp_script := load("res://client/scripts/prediction/entity_interpolator.gd")
		if interp_script != null and p._interpolator == null:
			p._interpolator = interp_script.new()
			p.add_child(p._interpolator)


## DS-M3: snapshot received from the dedicated server. Dispatch each entity
## record to the corresponding player's interpolator. Entities for peers we
## haven't seen yet are dropped silently — the spawn RPC will catch us up.
func _on_server_snapshot(tick: int, entities: Array) -> void:
	if not _server_is_dedicated:
		return
	# H5: drop stale snapshots so a late packet can't roll the world back over
	# a fresh one. unreliable_ordered guarantees in-channel order, but the
	# snapshot's effects (HP writes, ammo writes) can still get clobbered by
	# a stale duplicate that bypasses the channel's reorder buffer.
	if tick <= _last_snapshot_tick:
		return
	_last_snapshot_tick = tick
	var now_ms: float = float(Time.get_ticks_msec())
	for e in entities:
		var peer_id: int = int(e.get("p", 0))
		var p: Node = players_by_peer.get(peer_id)
		if p == null or not is_instance_valid(p):
			continue
		var pos: Vector3 = e.get("pos", Vector3.ZERO)
		var yaw: float = float(e.get("yaw", 0.0))
		var pitch: float = float(e.get("pitch", 0.0))
		if p.has_method(&"push_snapshot"):
			p.push_snapshot(now_ms, pos, yaw, pitch)
		# Sync HP from server-authoritative snapshot to the local view so the
		# HUD reflects the actual game state.
		#
		# NOT ammo: the server doesn't know about client-side weapon switches
		# (equip_slot() is local-only), so its ammo_in_mag is for whichever
		# weapon it thinks the player still holds (typically the starting
		# weapon). Pushing that back to the client overwrites the freshly
		# loaded SRX/sniper/etc magazine with the AK20's 29 rounds — kid
		# reported "切到狙击但开火表现还是 AK20". The server's ammo gate in
		# _on_client_fire_server still runs against the server's own counter;
		# they drift but neither corrupts the other. Proper fix needs a
		# client_switch_weapon RPC + server-tracked weapon_id in the snapshot
		# (codexreview.md 2026-05-25 P0 option 2 / test.md Bug A) — wired in
		# when the loadout/shop system goes live.
		if p.is_local:
			var hp: int = int(e.get("hp", -1))
			if hp >= 0 and "hp" in p:
				p.hp = float(hp)
				p.hp_changed.emit(p.hp, p.max_hp)


## Connection failures land us back at the main menu with a clear error
## instead of stuck on an infinite spinner.
func _on_connection_failed() -> void:
	push_warning("[client] connection failed")
	_show_connect_error("连接失败 — 检查地址/服务器是否在线")


func _on_server_disconnected() -> void:
	push_warning("[client] server disconnected")
	_show_connect_error("与服务器断开 — 服务器已关闭")


func _show_connect_error(msg: String) -> void:
	if connecting_overlay != null and connecting_overlay.has_method(&"show_error"):
		connecting_overlay.show_error(msg)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## DS-M5: server says a peer just respawned. Update local view immediately
## instead of waiting for the next snapshot (which would render a brief teleport).
func _on_server_respawn(peer_id: int, pos: Vector3) -> void:
	var p: Node = players_by_peer.get(peer_id)
	if p == null or not is_instance_valid(p):
		return
	if p.has_method(&"respawn"):
		p.respawn(pos)


## DS-M4: dedicated server dummy hit / killed observers. Log to stdout so the
## integration test can assert server-side fire actually landed damage.
func _on_dummy_damaged_ds(amount: float, is_headshot: bool, new_hp: float) -> void:
	print("[server] dummy hit: amount=%.1f head=%s new_hp=%.1f" % [amount, is_headshot, new_hp])


func _on_dummy_downed_ds() -> void:
	print("[server] dummy DOWN")


@rpc("any_peer", "reliable", "call_remote")
func _rpc_sync_request() -> void:
	if not multiplayer.is_server():
		return
	var requester: int = multiplayer.get_remote_sender_id()
	# C2: per-peer rate-limited (1/s). Re-syncs OUTSIDE the 1s window are
	# served (legit reason: the first sync's spawn RPC got dropped, or the
	# peer briefly re-mounted its game scene) — re-syncs INSIDE the window
	# are silently dropped. The 1s gate is what bounds the DoS: without it
	# an unauthenticated peer could spam this RPC and force the server to
	# rebroadcast N spawns per call — both a free DoS amplifier and a way
	# to insert themselves into _ready_peers before any auth check.
	var now_ms: int = Time.get_ticks_msec()
	if _synced_peers.has(requester):
		var last: int = int(_synced_peers[requester])
		if now_ms - last < 1000:
			return   # cooldown — silently drop the retry
		# Outside cooldown: still served, but log so we notice if it happens
		# regularly (would indicate the peer's first sync isn't sticking).
		if is_dedicated_server:
			print("[server] re-sync from peer %d (%dms since last)" % [requester, now_ms - last])
	_synced_peers[requester] = now_ms
	if not requester in _ready_peers:
		_ready_peers.append(requester)
	# Tell the client what map we're running BEFORE the spawn loop so the
	# client can swap geometry first; otherwise spawn positions land in
	# whatever map the client locally picked (which is meaningless — the
	# menu's MAP picker is host-only).
	#
	# F3-M3a: map is now per-room. Look up THIS REQUESTER's map (their
	# room's map if they're in one, else global) instead of the global
	# map_scene — otherwise joiners to two different concurrent matches
	# would get the same map info.
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		var their_map: String = _map_path_for_peer(requester)
		if not their_map.is_empty():
			net_rpc.server_map_info.rpc_id(requester, their_map)
	# Only spawn the requester's own room's players to them. Same logic
	# as above — sending a spawn for a peer in a different match would
	# materialize ghosts in the wrong client's world.
	var requester_room: String = _room_id_for_peer(requester)
	for peer in players_by_peer.keys():
		# MP path: same room only. Practice path (requester_room == "")
		# keeps the original "everyone visible" behavior.
		if not requester_room.is_empty() and _room_id_for_peer(peer) != requester_room:
			continue
		var peer_prof: Dictionary = _profile_for_peer(peer)
		_rpc_spawn.rpc_id(requester, peer, _spawn_pos_for(peer), peer_prof.name, peer_prof.skin)
	# F3 fix: inverse direction. _on_peer_connected_as_host now SKIPS the
	# spawn broadcast for lobbyists (the right call — they shouldn't ghost
	# into other rooms' matches), but that means same-room peers won't
	# see the requester unless we tell them here, when the requester
	# actually mounts game.tscn and we know which room they're in.
	# Sends spawn(requester) to OTHER same-room peers who are already in
	# game (in _ready_peers).
	if not requester_room.is_empty():
		var req_pos: Vector3 = _spawn_pos_for(requester)
		var req_prof: Dictionary = _profile_for_peer(requester)
		for peer in _ready_peers:
			if peer == requester or peer == multiplayer.get_unique_id():
				continue
			if _room_id_for_peer(peer) == requester_room:
				_rpc_spawn.rpc_id(peer, requester, req_pos, req_prof.name, req_prof.skin)
		# Send the initial scoreboard for this room so the requester sees
		# every player's name even before the first kill. Subsequent
		# updates ride on score_changed via _broadcast_scoreboard_for_room.
		_broadcast_scoreboard_for_room(requester_room)


# ── Spawn RPCs (server → all clients) ─────────────────────────────────────
## Carries name + skin so remote clients can render the player with their
## real identity instead of "P12345" + a peer-id-mod-18 skin. Defaulted
## to ("", 0) so the existing 5-arg call sites (and any future spawn that
## doesn't have a room context) still work.
@rpc("authority", "reliable", "call_remote")
func _rpc_spawn(peer_id: int, spawn_pos: Vector3, player_name: String = "", skin_index: int = 0) -> void:
	_local_spawn(peer_id, spawn_pos, player_name, skin_index)


@rpc("authority", "reliable", "call_remote")
func _rpc_despawn(peer_id: int) -> void:
	_despawn(peer_id)


## remote_name/remote_skin are populated by _rpc_spawn on the receiving
## client so we render the real lobby identity, not a peer-id placeholder.
## Server-side calls (where we know the local peer's Settings) pass the
## defaults and the local-vs-remote branch above resolves identity itself.
func _local_spawn(peer_id: int, spawn_pos: Vector3, remote_name: String = "", remote_skin: int = -1) -> void:
	if players_by_peer.has(peer_id):
		return
	var p: Node = PLAYER_SCENE.instantiate()
	p.name = "Player_%d" % peer_id
	p.weapon_def = AK20
	p.loadout = DEFAULT_LOADOUT
	# Pull persisted name + skin if this is the local user; remote peers
	# get a default skin keyed off their peer_id (M4 will sync real skins).
	var local_id: int = multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 0
	if peer_id == local_id and has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		p.player_name = s.player_name if not s.player_name.is_empty() else "P%d" % peer_id
		p.skin_index = s.skin_index
	else:
		# Remote peer: prefer the name/skin the server told us via _rpc_spawn
		# (synced from room.profiles). Falls back to placeholder if the
		# server didn't pass a profile — for example, a legacy / non-room
		# code path where there's nothing to look up.
		p.player_name = remote_name if not remote_name.is_empty() else "P%d" % peer_id
		p.skin_index = remote_skin if remote_skin >= 0 else absi(peer_id) % 18
	# Death routed to match_controller so scoring works regardless of MP/practice.
	# Capture peer_id explicitly so the lambda doesn't crash if the player node
	# is freed before we read it.
	var captured_peer: int = peer_id
	p.died.connect(func(killer): _on_any_player_died(captured_peer, killer))
	p.set_multiplayer_authority(peer_id)
	p.is_local = (peer_id == local_id)
	# Server-side mirrors of remote peers (dedicated OR listen-host) must
	# simulate from input bits on the authority side. Accepting raw transform
	# pushes lets the remote peer bypass CharacterBody3D collision entirely,
	# which is exactly the "walk through every wall/player" bug on host.
	if multiplayer.is_server() and peer_id != local_id:
		p.use_remote_input = true
	# DS-M3: on a DS client (we're connected to a dedicated server), no player
	# is locally authoritative — everyone is rendered from snapshots. The local
	# human additionally streams its input to the server each tick.
	if _server_is_dedicated and not is_dedicated_server:
		p.is_snapshot_only = true
	players_root.add_child(p)
	p.global_position = spawn_pos
	# Enable hit-detection on every player (so shots register).
	p.head_hitbox.monitoring = true
	p.body_hitbox.monitoring = true
	players_by_peer[peer_id] = p
	if p.is_local:
		local_player = p
		if hud != null:
			hud.bind_player(p)
		p.fired.connect(_on_local_fired)
		# Once our local player materializes, we're definitely past the connection
		# phase — dismiss the spinner if it's up.
		if connecting_overlay != null:
			connecting_overlay.dismiss()
	if hud != null:
		hud.push_feed("spawned peer %d" % peer_id, Color(0.6, 0.9, 1.0))
	if is_dedicated_server:
		print("[server] spawned player for peer %d at %s" % [peer_id, str(spawn_pos)])


func _despawn(peer_id: int) -> void:
	if not players_by_peer.has(peer_id):
		return
	var p: Node = players_by_peer[peer_id]
	# DS-M2: log final position before freeing so integration tests can
	# verify the server actually simulated movement from received input.
	if is_dedicated_server and is_instance_valid(p):
		var pos: Vector3 = p.global_position
		print("[server] peer %d final position: (%.3f, %.3f, %.3f)" % [peer_id, pos.x, pos.y, pos.z])
	if is_instance_valid(p):
		p.queue_free()
	players_by_peer.erase(peer_id)
	if hud != null:
		hud.push_feed("peer %d left" % peer_id, Color(1, 0.6, 0.4))
	if is_dedicated_server:
		print("[server] despawned peer %d" % peer_id)


# ── Spawn point selection ─────────────────────────────────────────────────
## Smart spawn: enumerate every Spawn marker in the map, score each by minimum
## distance to any living player (the farther the safer), and pick from the
## top half. Mirrors arena-shooter-3d/scripts/game.gd's anti-spawn-kill logic.
func _spawn_pos_for(peer_id: int) -> Vector3:
	# F3-M3a: read SpawnPoints from THIS PEER's room map, not the global
	# one. Practice peers (no room) still fall back to self.map_root.
	var peer_map: Node3D = _map_root_for_peer(peer_id)
	var spawn_root: Node = peer_map.get_node_or_null(^"SpawnPoints") if peer_map != null else null
	if spawn_root == null or spawn_root.get_child_count() == 0:
		return Vector3(0, 1, 0)

	# Gather living-player positions (exclude the peer being spawned).
	# Also scope to peers in the SAME room — anti-spawn-kill shouldn't
	# care about enemies in some other concurrent match.
	var peer_room: String = _room_id_for_peer(peer_id)
	var enemy_positions: Array = []
	for p in players_by_peer.keys():
		if p == peer_id:
			continue
		# In MP mode keep the comparison room-local. In practice (peer_room
		# is "") fall through to the old global behavior — there's only one
		# practice "room".
		if not peer_room.is_empty() and _room_id_for_peer(p) != peer_room:
			continue
		var pn: Node = players_by_peer[p]
		if pn != null and is_instance_valid(pn) and "is_dead" in pn and not pn.is_dead:
			enemy_positions.append(pn.global_position)

	# Score each candidate spawn by its distance to the NEAREST living enemy.
	# Higher score = safer.
	var candidates: Array = []
	for child in spawn_root.get_children():
		if not (child is Node3D):
			continue
		var pos: Vector3 = (child as Node3D).global_position
		var min_dist_sq: float = INF
		for ep in enemy_positions:
			var d: float = pos.distance_squared_to(ep)
			if d < min_dist_sq:
				min_dist_sq = d
		candidates.append({"pos": pos, "score": min_dist_sq})

	if candidates.is_empty():
		return Vector3(0, 1, 0)

	candidates.sort_custom(func(a, b): return a["score"] > b["score"])
	# Pick randomly from the top half so spawns aren't fully deterministic
	# (variety > pure optimum when multiple safe points exist).
	@warning_ignore("integer_division")
	var pick_pool: int = maxi(1, candidates.size() / 2)
	var idx: int = randi() % pick_pool
	return candidates[idx]["pos"]


# ── Server-authoritative fire resolution ──────────────────────────────────
# The 240-line resolver lives in server/scripts/fire_resolver.gd as a static
# method. This file just wires the RPC to it. Preload (not class_name) so
# headless tests don't depend on the editor having scanned the class registry.
const _FireResolver = preload("res://server/scripts/fire_resolver.gd")


func _on_client_fire_server(peer_id: int, weapon_id: StringName, fire_yaw: float = INF, fire_pitch: float = INF) -> void:
	_FireResolver.resolve_fire(self, peer_id, weapon_id, fire_yaw, fire_pitch)


## Listen-host server: client pressed ability, mirror the activation onto
## the server's view of their player so fire_resolver picks up the buff /
## powershot mults when the next fire RPC lands. Idempotent against the
## DS INPUT_ABILITY input-bit edge that also calls try_activate_ability —
## the cooldown guard inside try_activate_ability blocks the redundant call.
func _on_client_ability_server(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var shooter: Node = players_by_peer.get(peer_id)
	if shooter == null or not is_instance_valid(shooter):
		return
	if shooter.has_method(&"try_activate_ability"):
		shooter.try_activate_ability()




func _on_server_damage_broadcast(target: int, new_hp: float, src: int, _weapon: StringName, _headshot: bool) -> void:
	# Server already applied locally; only clients need to sync HP.
	if multiplayer.is_server():
		return
	var victim: Node = players_by_peer.get(target)
	if victim == null or not (victim is PlayerController):
		return
	# Force HP to server value rather than re-deriving — the server is truth.
	# H9: capture prev_hp before overwriting so the damage delta we display
	# is `prev - new`, not the previous typo `(max - new) * 2`.
	var prev_hp: float = victim.hp
	victim.hp = new_hp
	victim.hp_changed.emit(new_hp, victim.max_hp)
	# C6: do NOT call _die() here anymore — the server emits an explicit
	# server_player_died RPC for that. Routing death through one path means
	# clients can't get a stale damage packet to trigger a phantom death,
	# and the killer peer is always known (no more null last_attacker).
	# Optional UI feedback for the local player.
	if local_player != null and target == local_player.get_multiplayer_authority():
		hud.push_feed("hit by %d (-%d)" % [src, int(maxf(0.0, prev_hp - new_hp))], Color(1, 0.4, 0.4))


## C6: single death entrypoint on every non-server peer. Server already ran
## `_die` locally when apply_damage dropped HP to 0; this propagates the same
## state change to clients with the killer attribution intact.
## H10: doubles as the kill-confirm trigger in MP — when the killer is the
## local player, surface "ELIMINATED" / kill confirm via HUD.
func _on_server_player_died(victim_peer: int, killer_peer: int, _weapon: StringName, _headshot: bool) -> void:
	# Server already ran _die locally; this is the broadcast path for clients.
	if multiplayer.is_server():
		return
	var victim: Node = players_by_peer.get(victim_peer)
	if victim == null or not is_instance_valid(victim) or not (victim is PlayerController):
		return
	if victim.is_dead:
		return   # already processed (snapshot or earlier RPC); idempotent
	# Wire the killer reference into the victim so `last_attacker` is correct
	# for downstream signals (kill feed, scoring, replay).
	var killer_node: Node = players_by_peer.get(killer_peer)
	if killer_node != null and is_instance_valid(killer_node):
		victim.last_attacker = killer_node
	victim._die()
	# H10: kill confirm — only when the LOCAL player landed the killing shot.
	if hud != null and local_player != null \
			and killer_peer == local_player.get_multiplayer_authority() \
			and killer_peer != victim_peer:
		var vname: String = victim.player_name if "player_name" in victim else "enemy"
		hud.show_kill_confirm(vname)


func _resolve_weapon(id: StringName) -> Resource:
	if weapon_registry != null:
		var hit: Resource = weapon_registry.get_weapon(id)
		if hit != null:
			return hit
	# Fallback for the small set if registry unavailable.
	match id:
		&"ak20": return AK20
		&"sg8":  return SG8
		&"srx":  return SRX
		&"railgun": return RAILGUN
		&"crossbow": return CROSSBOW
		_: return null


# ── Feedback ──────────────────────────────────────────────────────────────
func _on_local_fired(weapon: Resource, hit_info: Dictionary) -> void:
	# Play the fire blip regardless of hit/miss.
	var proc_audio: Node = get_node_or_null(^"/root/ProcAudio")
	if proc_audio != null and proc_audio.has_method(&"play_fire"):
		proc_audio.play_fire()

	if hit_info.is_empty():
		return
	var collider: Node = hit_info.collider
	if collider == null or not collider.has_meta(&"owner_player"):
		return
	var is_head: bool = collider.get_meta(&"is_head", false)
	hud.flash_hit(is_head)
	# Floating damage number in 3D world space.
	var dmg: float = PlayerController._compute_damage(weapon, is_head) if weapon != null else 0.0
	if dmg > 0.5:
		_spawn_damage_label(hit_info.position, int(round(dmg)), is_head)
	# Kill confirmation — if this shot will drop the victim, show the big
	# center-screen "ELIMINATED" pop. (Practice mode only — in MP the server
	# authoritative damage path emits its own death signal that the HUD picks
	# up via _on_server_damage_broadcast.)
	if not _is_networked():
		var victim: Node = collider.get_meta(&"owner_player")
		var already_down: bool = (("is_dead" in victim) and victim.is_dead) or (("is_down" in victim) and victim.is_down)
		if victim != null and "hp" in victim and not already_down and victim.hp - dmg <= 0.0:
			var vname: String = victim.player_name if "player_name" in victim else "enemy"
			hud.show_kill_confirm(vname)


func _spawn_damage_label(world_pos: Vector3, dmg: int, is_head: bool) -> void:
	var label := Label3D.new()
	label.text = ("HEAD %d" % dmg) if is_head else str(dmg)
	label.font_size = 96 if is_head else 64
	label.outline_size = 14
	label.outline_modulate = Color(0, 0, 0, 1)
	label.modulate = Color(1, 0.9, 0.25) if is_head else Color(1, 0.55, 0.55)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.004
	add_child(label)
	label.global_position = world_pos + Vector3(0, 0.15, 0)
	# Float up + fade out.
	var t: Tween = label.create_tween()
	t.set_parallel(true)
	t.tween_property(label, "global_position", world_pos + Vector3(0, 1.1, 0), 0.85)
	t.tween_property(label, "modulate:a", 0.0, 0.85)
	t.chain().tween_callback(label.queue_free)


func _on_dummy_damaged(amount: float, is_headshot: bool, new_hp: float) -> void:
	var label: String = "HEAD %d" % int(amount) if is_headshot else "hit %d" % int(amount)
	hud.push_feed("%s  →  dummy %d hp" % [label, int(new_hp)],
		Color(1, 0.85, 0.2) if is_headshot else Color.WHITE)


func _on_dummy_downed() -> void:
	hud.push_feed("DUMMY DOWN — respawn 3s", Color(0.2, 1.0, 0.4))


# ── Match scoring hook ────────────────────────────────────────────────────
func _on_any_player_died(victim_peer: int, killer: Node) -> void:
	# Tell the match controller (if any).
	var killer_peer: int = 0
	if killer != null and killer is PlayerController:
		for p in players_by_peer.keys():
			if players_by_peer[p] == killer:
				killer_peer = p
				break
	# F3-M2: prefer the room's match_controller (MP path) over the global
	# one (practice path). The victim's room is the source of truth for
	# scoring — `peer_to_room[victim_peer]` tells us which match cares.
	var scoring_mc: Node = _resolve_match_controller_for_peer(victim_peer)
	if scoring_mc != null:
		scoring_mc.record_kill(killer_peer, victim_peer)

	# R1: single death-broadcast point. Every kill source (gun, damage_zone,
	# admin nuke, headless_main --test-kill hooks, future map gimmicks) hits
	# `died.emit()` → here. Previously the broadcast lived in the
	# _on_client_fire_server bullet path only, so poison-pool / admin-nuke
	# victims looked alive on every non-host client for the full 3s respawn
	# window. Weapon / headshot attribution isn't propagated for non-bullet
	# deaths — the client-side handler ignores those fields today; revisit
	# when kill feed wants per-source icons.
	if is_dedicated_server or (multiplayer.has_multiplayer_peer() and multiplayer.is_server()):
		var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
		if net_rpc != null:
			# F3-M3c: scope death feed to the victim's room. Empty audience
			# falls back to the legacy global broadcast for test setups
			# that connect to the DS without going through the lobby.
			var audience: Array = _room_scoped_audience(victim_peer)
			if audience.is_empty():
				net_rpc.server_player_died.rpc(victim_peer, killer_peer, &"", false)
			else:
				var live: Array = multiplayer.get_peers()
				for peer in audience:
					if peer in live:
						net_rpc.server_player_died.rpc_id(peer, victim_peer, killer_peer, &"", false)

	# Economy: if the LOCAL player got the kill, award credits per mode_def.
	# Persisted via Settings autoload so progress survives between sessions.
	var settings_node: Node = get_node_or_null(^"/root/Settings")
	if settings_node != null and local_player != null and killer == local_player:
		var per_kill: int = 5
		if mode_def != null and "credits_per_kill" in mode_def:
			per_kill = mode_def.credits_per_kill
		settings_node.award_credits(per_kill)
		if hud != null:
			hud.push_feed("+%d 💰" % per_kill, Color(1, 0.85, 0.3))
		# Stat persistence — overall K/D tracked in StatsStore for menus.
		var stats_node: Node = get_node_or_null(^"/root/StatsStore")
		if stats_node != null:
			stats_node.record_kill(settings_node.player_name, "peer_%d" % victim_peer)

	# DS-M5: server-driven respawn in MP. The server is authoritative — it
	# picks the spawn point, respawns the player after the delay, and broadcasts
	# server_player_respawned so every client updates its view. Clients receive
	# the RPC via _on_server_respawn (already wired in _enter_client_mode).
	var victim: Node = players_by_peer.get(victim_peer)
	if victim == null or not is_instance_valid(victim):
		return
	if is_dedicated_server or (multiplayer.has_multiplayer_peer() and multiplayer.is_server()):
		# Authority side: schedule respawn for any player that died.
		if is_dedicated_server:
			print("[server] peer %d died — respawning in 3s" % victim_peer)
		var pos: Vector3 = _spawn_pos_for(victim_peer)
		# H2: only one outstanding respawn timer per peer. If a stale death
		# event fires while a respawn is already queued (or the player dies
		# again during the down state), drop the duplicate rather than
		# stacking timers that would overwrite each other on fire.
		if _pending_respawn.has(victim_peer):
			if is_dedicated_server:
				print("[server]   ↳ respawn already pending for %d, skipping" % victim_peer)
			return
		var t: SceneTreeTimer = get_tree().create_timer(3.0)
		_pending_respawn[victim_peer] = t
		t.timeout.connect(_ds_respawn_player.bind(victim_peer, pos))
		return
	# Listen-host client / DS client: nothing to do — server will broadcast.
	if not victim.is_local:
		return   # remote/bot respawn handled by host or server
	if _is_networked():
		if hud != null:
			hud.push_feed("YOU DIED — server respawning…", Color(1, 0.4, 0.4))
		return
	# Practice / offline: respawn locally after 3s.
	if hud != null:
		hud.push_feed("YOU DIED — respawn in 3s", Color(1, 0.4, 0.4))
	var pos2: Vector3 = _spawn_pos_for(victim_peer)
	get_tree().create_timer(3.0).timeout.connect(_do_local_respawn.bind(victim, pos2))


## DS-M5: authoritative respawn. Runs on host / dedicated server. Calls the
## victim's respawn() locally to reset HP + collision + position, then
## broadcasts server_player_respawned so all clients update their view.
func _ds_respawn_player(victim_peer: int, pos: Vector3) -> void:
	# H2: consume the pending-timer slot regardless of whether the player is
	# still around (a peer can disconnect during the 3s window).
	_pending_respawn.erase(victim_peer)
	var victim: Node = players_by_peer.get(victim_peer)
	if victim == null or not is_instance_valid(victim):
		return
	victim.respawn(pos)
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		# F3-M3c: scope respawn announcement to the victim's room.
		var audience: Array = _room_scoped_audience(victim_peer)
		if audience.is_empty():
			net_rpc.server_player_respawned.rpc(victim_peer, pos)
		else:
			var live: Array = multiplayer.get_peers()
			for peer in audience:
				if peer in live:
					net_rpc.server_player_respawned.rpc_id(peer, victim_peer, pos)
	if is_dedicated_server:
		print("[server] peer %d respawned at (%.2f, %.2f, %.2f)" % [victim_peer, pos.x, pos.y, pos.z])


func _do_local_respawn(victim: Node, pos: Vector3) -> void:
	if victim == null or not is_instance_valid(victim):
		return
	victim.respawn(pos)
	if hud != null:
		hud.push_feed("respawned — go!", Color(0.5, 1.0, 0.5))


func _on_round_ended(winner: int, _scores: Dictionary) -> void:
	if hud != null:
		hud.push_feed("Round ended — winner peer %d" % winner, Color(0.9, 0.9, 0.4))


func _on_match_ended(winner: int, final: Dictionary, room_id: String = "") -> void:
	if hud != null:
		hud.push_feed("MATCH OVER — winner peer %d" % winner, Color(1.0, 0.85, 0.2))
	# Dedicated server: kick off the end-of-match flow via RoomManager.
	# RoomManager.end_match flips state + emits match_finished, which our
	# _on_match_finished_in_room handler picks up to tear down the world.
	# That single-source-of-truth split also catches abrupt match-end
	# (host disconnect → room_destroyed → same teardown).
	# Listen-host / practice: pop up the themed scoreboard (legacy flow).
	if is_dedicated_server:
		print("[server] match ended — winner peer %d (room=%s)" % [winner, room_id])
		# F3-M5: end_match the SPECIFIC room that ended, not "the one
		# active room" (which is no longer a singleton). Practice / pre-
		# room path passes "" — fall back to the legacy global self.match_controller
		# cleanup via _tear_down_match_world("").
		if not room_id.is_empty():
			var room_mgr: Node = get_node_or_null(^"/root/RoomManager")
			if room_mgr != null:
				room_mgr.end_match(room_id)
		return
	# Pop up the themed end-of-match scoreboard.
	var screen: Node = MATCH_END_SCENE.instantiate()
	add_child(screen)
	var my_id: int = multiplayer.get_unique_id() if _is_networked() else 1
	screen.show_for(winner, final, my_id)
	# Release the cursor so the user can click "Return / Play again".
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# ── Lobby: per-room match boot ───────────────────────────────────────────
# F3-M5: the singleton `_active_room_id` is gone. `room_worlds` (a dict
# keyed by room_id, see field declaration near map_root) is the authoritative
# "which matches are currently running" registry. has-key checks replaced
# the empty-string sentinel everywhere.


## Called by RoomManager.match_started when a room's host clicks START.
## Phase 1 model is single-shared-world (per .agent/lobby_plan.md): peers
## were already auto-spawned in _on_peer_connected_as_host when they
## joined the DS, so this just swaps the map, sets up the room's mode,
## repositions the room's players, and broadcasts server_match_starting
## so the clients transition out of room_lobby.tscn into game.tscn.
func _boot_match_for_room(room) -> void:
	if not is_dedicated_server or not multiplayer.is_server():
		return
	# F3-M5: concurrent matches. Idempotency guard — same room booted
	# twice (rare race) should no-op rather than stack RoomWorld instances.
	if room_worlds.has(room.room_id):
		push_warning("[server] _boot_match_for_room called for %s but it's already booted" % room.room_id)
		return
	print("[server] booting match for room %s (%d players, map=%s)" % \
		[room.room_id, room.players.size(), room.map_path])

	# F3-M1/M3a: stand up a per-room World3D container and load the
	# room's map under it. self.map_root is left alone — practice mode
	# still uses it. _map_root_for_peer / _map_path_for_peer route peer-
	# scoped lookups to the right place.
	var room_world: SubViewport = _ROOM_WORLD_SCRIPT.new()
	room_world.set("room_id", room.room_id)
	room_world.name = "RoomWorld_%s" % room.room_id
	add_child(room_world)
	room_worlds[room.room_id] = room_world
	# load_map() handles the blank.tscn fallback internally for bad paths.
	if room_world.call("load_map", room.map_path) == null:
		push_warning("[server] room %s failed to mount any map (bad path: %s)" % [room.room_id, room.map_path])

	# F3-M3b: reparent the room's players from the global `players_root`
	# into the room's own SubViewport. This is what gives us actual world
	# isolation: a CharacterBody3D inside a SubViewport with own_world_3d
	# auto-rebinds its physics RID to that subview's space on next physics
	# step, so raycasts in room A can no longer hit colliders in room B.
	#
	# reparent() (Godot 4) preserves the global transform and re-fires
	# NOTIFICATION_ENTER_TREE so per-frame physics state is consistent.
	var room_players_root: Node = room_world.get("players_root")
	if room_players_root != null and is_instance_valid(room_players_root):
		for peer in room.players:
			if not players_by_peer.has(peer):
				continue
			var pn: Node = players_by_peer[peer]
			if not is_instance_valid(pn):
				continue
			if pn.get_parent() != room_players_root:
				pn.reparent(room_players_root, false)

	# F3-M2: per-room match_controller. Live as a child of room_world so
	# the RoomWorld lifecycle (born here, freed in _tear_down_match_world)
	# cascades cleanup automatically. self.match_controller is now reserved
	# for the practice path; the MP path uses room_worlds[id].match_controller.
	#
	# The any "global" match_controller built at _ready time (practice mode,
	# or the legacy pre-room-system listen-host path) is left alone. Without
	# this the practice → MP transition would unhook its scoring loop.
	if not room.mode_def_path.is_empty():
		var md: Resource = load(room.mode_def_path)
		if md != null:
			mode_def = md
			var mc_script := load("res://shared/scripts/match_controller.gd")
			if mc_script != null:
				var room_mc: Node = mc_script.new()
				room_mc.mode_def = md
				room_world.add_child(room_mc)
				# F3-M5: bind the room_id so _on_match_ended knows WHICH
				# concurrent match ended without consulting a singleton.
				room_mc.match_ended.connect(_on_match_ended.bind(room.room_id))
				room_mc.round_ended.connect(_on_round_ended)
				# Scoreboard: every kill ticks score_changed for one peer.
				# Translate that into a full-room broadcast so every client's
				# HUD scoreboard re-renders the leaderboard. Bind the room_id
				# so the broadcaster knows the audience without consulting
				# any room-state singleton.
				room_mc.score_changed.connect(
					func(_p, _k, _d): _broadcast_scoreboard_for_room(room.room_id))
				room_world.set("match_controller", room_mc)
				room_mc.start()

	# Players are already spawned (auto-spawn on peer_connect). But their
	# positions were from the OLD map's spawn points (or default 0,0,0).
	# Reposition each room player to the new map's spawn points so they
	# don't materialize inside a KOTH wall after a Trenches → KOTH swap.
	for peer in room.players:
		if players_by_peer.has(peer):
			var p: Node = players_by_peer[peer]
			if is_instance_valid(p) and p.has_method(&"respawn"):
				p.respawn(_spawn_pos_for(peer))

	# Tell the room's clients the match is on — they transition from
	# room_lobby.tscn into game.tscn, which then runs _enter_client_mode
	# → sends client_hello + sync_request → server replies with
	# server_map_info + spawn RPCs (the same path used everywhere else).
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		var live: Array = multiplayer.get_peers()
		for peer in room.players:
			if peer in live:
				net_rpc.server_match_starting.rpc_id(peer)


## M3: hooked to RoomManager.match_finished. Fires from either path that
## ends an active match — match_controller's win-condition signal (via
## _on_match_ended → RoomManager.end_match → match_finished) OR an abrupt
## end where the room is being destroyed and we get here via the parallel
## room_destroyed → _on_room_destroyed_check_active path. Phase 1 keeps
## players spawned + map loaded between matches; room host can just hit
## START again.
func _on_match_finished_in_room(room) -> void:
	# F3-M5: concurrent matches — accept any room that we currently track.
	# Pre-M5 single-active-match check (`room.room_id != _active_room_id`)
	# is gone; we just need this room to actually be one we booted.
	if not room_worlds.has(room.room_id):
		return
	_tear_down_match_world(room.room_id)


## Companion to the above for the disconnect / host-leave path: when a
## room is destroyed and it happened to be one we'd booted, tear down
## just that one (other concurrent rooms continue running).
func _on_room_destroyed_check_active(room_id: String, _evicted: Array) -> void:
	if not room_worlds.has(room_id):
		return
	_tear_down_match_world(room_id)
	# room_destroyed already broadcast server_room_destroyed to the
	# evicted set; their game scenes need an extra nudge back to the
	# room_browser (no room exists for them to return to). Reuse the
	# match_ended path with an empty room_state.
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		var live: Array = multiplayer.get_peers()
		for peer in _evicted:
			if peer in live:
				net_rpc.server_match_ended.rpc_id(peer, {})


## Pure local cleanup of the DS's match world. Does NOT call back into
## RoomManager — both callers above arrived here BECAUSE of RoomManager
## signals firing, so a callback would cycle.
## F3-M2: pick the match_controller that should record this peer's
## kill / score events. MP peers in a room → that room's MC; practice
## or out-of-room peers → the global self.match_controller.
##
## Returns null if there's nothing to score against (e.g. a peer that
## died before any match started). Caller no-ops on null.
func _resolve_match_controller_for_peer(peer_id: int) -> Node:
	# Reuse _room_id_for_peer so the property-access workaround stays in
	# exactly one place (Godot 4 `in` operator vs script-level vars, see
	# _room_id_for_peer comment).
	var rid: String = _room_id_for_peer(peer_id)
	if not rid.is_empty() and room_worlds.has(rid):
		var rw: Node = room_worlds[rid]
		if is_instance_valid(rw):
			var room_mc: Variant = rw.get("match_controller")
			if room_mc != null and is_instance_valid(room_mc):
				return room_mc
	return match_controller


## F3 follow-up: read a peer's lobby identity (name + skin index) so we
## can ship it inside _rpc_spawn to remote clients. Without this, every
## remote peer renders as "P12345" and a default skin instead of the
## name/skin the user picked in the menu.
##
## Returns {"name": String, "skin": int}. Falls back to ("", 0) when
## the peer isn't in any room — caller's responsibility to pick a
## default for that case.
func _profile_for_peer(peer_id: int) -> Dictionary:
	var rid: String = _room_id_for_peer(peer_id)
	if rid.is_empty():
		return {"name": "", "skin": 0}
	var rm: Node = get_node_or_null(^"/root/RoomManager")
	if rm == null:
		return {"name": "", "skin": 0}
	var rooms: Dictionary = rm.rooms
	if not rooms.has(rid):
		return {"name": "", "skin": 0}
	var room: Variant = rooms[rid]
	var profiles: Dictionary = room.profiles
	var p: Dictionary = profiles.get(peer_id, {"name": "", "skin": 0})
	return {"name": String(p.get("name", "")), "skin": int(p.get("skin", 0))}


## F3-M3a: look up the room a peer belongs to, or "" if they're not in
## a room (practice / pre-lobby). Centralized so every per-room dispatcher
## (map, players, snapshot, damage) shares one source of truth and an
## eventual RoomManager rename only changes one place.
func _room_id_for_peer(peer_id: int) -> String:
	var rm: Node = get_node_or_null(^"/root/RoomManager")
	if rm == null:
		return ""
	return String(rm.peer_to_room.get(peer_id, ""))


## F3-M3a: the RoomWorld for a peer (or null if they're not in a match).
## Returns null even if the peer's room exists but hasn't started — only
## active matches mount a RoomWorld in `room_worlds`.
func _room_world_for_peer(peer_id: int) -> Node:
	var rid: String = _room_id_for_peer(peer_id)
	if rid.is_empty() or not room_worlds.has(rid):
		return null
	var rw: Node = room_worlds[rid]
	return rw if is_instance_valid(rw) else null


## F3-M3a: the map Node3D containing `peer_id` — room's map if they're
## in a match, otherwise GameController.map_root (practice fallback).
## Returns null only if NO map exists at all, which shouldn't happen on
## a healthy server but callers should null-check defensively.
func _map_root_for_peer(peer_id: int) -> Node3D:
	var rw: Node = _room_world_for_peer(peer_id)
	if rw != null:
		var rm_map: Variant = rw.get("map_root")
		if rm_map != null and is_instance_valid(rm_map):
			return rm_map
	return map_root


## F3-M3c: audience for an event scoped to a single peer. Returns the
## peers in the same room (so server_player_died etc. only fan out to
## that match's clients) or an empty array if `peer_id` isn't in a
## live room. Callers use the empty case as the signal to fall back to
## a global `.rpc()` broadcast (legacy / test-suite behavior).
func _room_scoped_audience(peer_id: int) -> Array:
	var rid: String = _room_id_for_peer(peer_id)
	if rid.is_empty():
		return []
	var rm: Node = get_node_or_null(^"/root/RoomManager")
	if rm == null:
		return []
	# Same direct-access pattern as _room_id_for_peer.
	var rooms: Dictionary = rm.rooms
	if not rooms.has(rid):
		return []
	var room: Variant = rooms[rid]
	return (room.players as Array).duplicate()


## Build + ship a fresh scoreboard for `room_id`. Called every time the
## room's match_controller emits score_changed. Each row carries the
## peer's lobby identity (name + skin) so the client doesn't need a
## second lookup. Sent only to the room's own peers — concurrent rooms
## each see their own leaderboard.
func _broadcast_scoreboard_for_room(room_id: String) -> void:
	var rm: Node = get_node_or_null(^"/root/RoomManager")
	if rm == null:
		return
	var rooms: Dictionary = rm.rooms
	if not rooms.has(room_id):
		return
	var room: Variant = rooms[room_id]
	var rw: Variant = room_worlds.get(room_id)
	if rw == null or not is_instance_valid(rw):
		return
	var mc: Variant = rw.get("match_controller")
	if mc == null or not is_instance_valid(mc):
		return
	# Build one row per room player. Read kills/deaths from match_controller
	# (per-room since F3-M2). Profile (name + skin) lives on room.profiles.
	var rows: Array = []
	var kills: Dictionary = mc.kills
	var deaths: Dictionary = mc.deaths
	var profiles: Dictionary = room.profiles
	for peer in room.players:
		var prof: Dictionary = profiles.get(peer, {"name": "", "skin": 0})
		var n: String = String(prof.get("name", ""))
		if n.is_empty():
			n = "P%d" % peer
		rows.append({
			"peer":   peer,
			"name":   n,
			"skin":   int(prof.get("skin", 0)),
			"kills":  int(kills.get(peer, 0)),
			"deaths": int(deaths.get(peer, 0)),
		})
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		return
	var live: Array = multiplayer.get_peers()
	for peer in room.players:
		if peer in live:
			net_rpc.server_score_update.rpc_id(peer, rows)


## F3-M3a: res:// path of the map containing `peer_id`. Used by
## _rpc_sync_request to tell each joiner which scene to load locally.
## Empty if neither a room map nor a global fallback exists.
func _map_path_for_peer(peer_id: int) -> String:
	var m: Node3D = _map_root_for_peer(peer_id)
	if m != null and m.scene_file_path != "":
		return m.scene_file_path
	if map_scene != null and not map_scene.resource_path.is_empty():
		return map_scene.resource_path
	return ""


func _tear_down_match_world(ended_room_id: String = "") -> void:
	# F3-M5: caller passes the room_id to tear down (concurrent matches —
	# you need to say which one ended). The empty-default path is kept
	# for the rare callers that pre-dated concurrency, but in practice
	# every live call site supplies an explicit room.
	# F3-M1 + M2: free the RoomWorld. Its match_controller child is a
	# descendant so queue_free cascades — no separate match_controller
	# cleanup needed for the MP path. self.match_controller is left alone
	# (practice mode keeps it). erase() AFTER queue_free so the dict entry
	# isn't pointing at a half-freed node mid-frame.
	if not ended_room_id.is_empty() and room_worlds.has(ended_room_id):
		var rw: Node = room_worlds[ended_room_id]
		if is_instance_valid(rw):
			# F3-M3b: reparent the room's surviving players back to the
			# global players_root BEFORE the RoomWorld dies — otherwise
			# queue_free cascades and takes the players with it, which
			# breaks the post-match lobby flow (their game scenes expect
			# to receive room_state with their own peer IDs still spawned
			# server-side, ready to be repositioned for round 2).
			var room_players_root: Node = rw.get("players_root")
			if room_players_root != null and is_instance_valid(room_players_root):
				for child in room_players_root.get_children():
					if is_instance_valid(child):
						child.reparent(players_root, false)
			rw.queue_free()
		room_worlds.erase(ended_room_id)
