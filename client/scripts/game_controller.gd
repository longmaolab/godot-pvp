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
		# DS-M2: per-tick input RPCs from clients → routed to the corresponding
		# server-side PlayerController. The player simulates physics with this
		# input instead of reading Input.* (which is meaningless on the server).
		if not net_rpc.client_input_received.is_connected(_on_client_input_ds):
			net_rpc.client_input_received.connect(_on_client_input_ds)


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
	# Build snapshot payload: one flat dict per player. Cheap to serialize
	# over WebSocket and easy for clients to consume without schema changes.
	var entities: Array = []
	for peer_id in players_by_peer.keys():
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
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		return
	# Broadcast to every client. unreliable_ordered: snapshots are idempotent
	# (latest wins), don't retransmit drops.
	net_rpc.server_send_snapshot.rpc(_snapshot_tick, entities)


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
	# C2 + R4: free per-peer rate-limit state so the dict doesn't grow
	# unboundedly across connect/disconnect cycles, AND so a recycled
	# peer-id doesn't inherit the previous occupant's chat quota.
	_synced_peers.erase(peer)
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null and net_rpc.has_method(&"forget_peer"):
		net_rpc.forget_peer(peer)
	_rpc_despawn.rpc(peer)
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
		if not net_rpc.server_snapshot_received.is_connected(_on_server_snapshot):
			net_rpc.server_snapshot_received.connect(_on_server_snapshot)
		if not net_rpc.server_respawn_received.is_connected(_on_server_respawn):
			net_rpc.server_respawn_received.connect(_on_server_respawn)
		# C6: explicit death broadcast — single source of truth for kills.
		if not net_rpc.server_death_received.is_connected(_on_server_player_died):
			net_rpc.server_death_received.connect(_on_server_player_died)
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
	for peer in players_by_peer.keys():
		_rpc_spawn.rpc_id(requester, peer, _spawn_pos_for(peer))


# ── Spawn RPCs (server → all clients) ─────────────────────────────────────
@rpc("authority", "reliable", "call_remote")
func _rpc_spawn(peer_id: int, spawn_pos: Vector3) -> void:
	_local_spawn(peer_id, spawn_pos)


@rpc("authority", "reliable", "call_remote")
func _rpc_despawn(peer_id: int) -> void:
	_despawn(peer_id)


func _local_spawn(peer_id: int, spawn_pos: Vector3) -> void:
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
		p.player_name = "P%d" % peer_id
		p.skin_index = absi(peer_id) % 18
	# Death routed to match_controller so scoring works regardless of MP/practice.
	# Capture peer_id explicitly so the lambda doesn't crash if the player node
	# is freed before we read it.
	var captured_peer: int = peer_id
	p.died.connect(func(killer): _on_any_player_died(captured_peer, killer))
	p.set_multiplayer_authority(peer_id)
	p.is_local = (peer_id == local_id)
	# DS-M2: on a dedicated server, the server owns every player's simulation
	# but consumes input over the network. Mark these players so they read
	# from push_remote_input instead of Input.* / _apply_remote_state.
	if is_dedicated_server and peer_id != local_id:
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
	var spawn_root: Node = map_root.get_node_or_null(^"SpawnPoints") if map_root != null else null
	if spawn_root == null or spawn_root.get_child_count() == 0:
		return Vector3(0, 1, 0)

	# Gather living-player positions (exclude the peer being spawned).
	var enemy_positions: Array = []
	for p in players_by_peer.keys():
		if p == peer_id:
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
const _SHOOT_MASK_SERVER: int = (1 << 0) | (1 << 2)


## Resolves a fire intent from the given peer using the host's own view of the
## world. Only the host runs this; result is broadcast via server_apply_damage.
## DS-M4 fix: the shooter's instantaneous yaw/pitch are sent with the fire RPC,
## so the server raycasts at the EXACT direction the client was looking instead
## of using its interp-delayed view of the shooter's transform.
func _on_client_fire_server(peer_id: int, weapon_id: StringName, fire_yaw: float = INF, fire_pitch: float = INF) -> void:
	if not multiplayer.is_server():
		return
	if is_dedicated_server:
		print("[server] fire peer=%d weapon=%s aim=(%.3f,%.3f)" % [peer_id, weapon_id, fire_yaw, fire_pitch])
	var shooter: Node = players_by_peer.get(peer_id)
	if shooter == null:
		if is_dedicated_server:
			print("[server]   ↳ ignored: shooter not in players_by_peer (keys=%s)" % str(players_by_peer.keys()))
		return
	if shooter.is_dead:
		if is_dedicated_server:
			print("[server]   ↳ ignored: shooter is dead")
		return
	# C3: server-authoritative gate. Run BEFORE any state mutation so this
	# handler enforces ammo / cooldown / reload regardless of whether the
	# RPC came via try_fire (legit input bit) or a direct client_fire spam.
	if shooter.is_reloading:
		if is_dedicated_server:
			print("[server]   ↳ ignored: shooter is reloading")
		return
	if shooter.time_until_next_shot > 0.0:
		if is_dedicated_server:
			print("[server]   ↳ ignored: cooldown %.3fs remaining" % shooter.time_until_next_shot)
		return
	if shooter.ammo_in_mag <= 0:
		# Auto-reload on empty mag — matches try_fire() line 712. Without this,
		# direct client_fire RPCs (which skip try_fire's reload trigger) leave
		# the server's ammo pinned at 0 forever, and the player can't shoot
		# again even though they're holding the trigger. User-reported bug:
		# "子弹打完之后没有自动装弹，不能继续玩".
		if not shooter.is_reloading:
			shooter.start_reload()
		if is_dedicated_server:
			print("[server]   ↳ ignored: empty mag → auto-reload triggered")
		return
	var weapon: Resource = _resolve_weapon(weapon_id)
	if weapon == null:
		push_warning("[server] unknown weapon_id: %s" % weapon_id)
		return
	# C3: shooter must actually own this weapon. Otherwise a peer can pass
	# &"railgun" while equipped with an AK and get railgun damage every shot.
	var weapon_in_loadout: bool = false
	for w in shooter.loadout:
		if w != null and StringName(w.id) == weapon_id:
			weapon_in_loadout = true
			break
	if not weapon_in_loadout:
		if is_dedicated_server:
			print("[server]   ↳ ignored: weapon %s not in shooter's loadout" % weapon_id)
		return
	# C4: clamp aim against the shooter's last validated input frame. A real
	# human can't snap-aim more than ~PI per fire interval, so anything past
	# MAX_AIM_DELTA_RAD almost certainly came from a teleport-aim cheat.
	# Skip on first fire (no baseline yet) and when aim wasn't provided.
	if fire_yaw != INF and fire_pitch != INF:
		if not (is_finite(fire_yaw) and is_finite(fire_pitch)):
			if is_dedicated_server:
				print("[server]   ↳ ignored: non-finite aim")
			return
		# R2: pick the correct aim baseline for this peer's connection mode.
		# DS path → server replays inputs into _remote_input_yaw/pitch.
		# Listen-host path → use_remote_input=false; instead the remote
		# client's last `_net_apply_state` RPC populates _net_remote_yaw/pitch.
		# Previously this branch was gated solely on use_remote_input, so on
		# every listen-host LAN game the snap-aim cheat check was a no-op.
		var have_baseline: bool = false
		var baseline_yaw: float = 0.0
		var baseline_pitch: float = 0.0
		if shooter.use_remote_input and shooter._remote_input_tick >= 0:
			have_baseline = true
			baseline_yaw = shooter._remote_input_yaw
			baseline_pitch = shooter._remote_input_pitch
		elif "_net_has_remote_target" in shooter and shooter._net_has_remote_target:
			have_baseline = true
			baseline_yaw = shooter._net_remote_yaw
			baseline_pitch = shooter._net_remote_pitch
		if have_baseline:
			var dy: float = absf(wrapf(fire_yaw - baseline_yaw, -PI, PI))
			var dp: float = absf(fire_pitch - baseline_pitch)
			if dy > NetProtocol.MAX_AIM_DELTA_RAD or dp > NetProtocol.MAX_AIM_DELTA_RAD:
				if is_dedicated_server:
					print("[server]   ↳ ignored: aim delta yaw=%.2f pitch=%.2f exceeds %.2f" % [dy, dp, NetProtocol.MAX_AIM_DELTA_RAD])
				return
	# C3 commit: decrement ammo + arm cooldown HERE (try_fire defers these on
	# server-authoritative paths so we have a single source of truth).
	shooter.ammo_in_mag -= 1
	shooter.time_until_next_shot = weapon.fire_interval_seconds()
	shooter.ammo_changed.emit(shooter.ammo_in_mag, shooter.ammo_reserve)
	# If the client sent aim, snap the shooter's body/head to that direction
	# BEFORE the raycast so the ray comes out of the camera in the right line.
	# We restore the interpolated state in the saved_positions loop below.
	var saved_shooter_aim: Dictionary = {}
	if fire_yaw != INF and fire_pitch != INF and shooter.has_node(^"Head"):
		saved_shooter_aim = {
			"yaw":   shooter.rotation.y,
			"pitch": shooter.head.rotation.x,
		}
		shooter.rotation.y = fire_yaw
		shooter.head.rotation.x = clampf(fire_pitch, -PI * 0.49, PI * 0.49)

	# ── Lag compensation: temporarily rewind every other player to where they
	# were on the shooter's screen when they pulled the trigger. The shooter
	# saw targets at (now - interp_delay - ping/2). Without rewinding the full
	# amount, the server's raycast hits where targets ARE, not where the
	# shooter SAW them, and shots feel "should have hit" but don't register. ──
	var saved_positions: Dictionary = {}
	if lag_compensation_enabled and lag_comp != null:
		var rewind_ms: float = float(NetProtocol.SNAPSHOT_INTERPOLATION_MS) + default_lag_comp_ping_ms * 0.5
		var rewind_to_ms: float = float(Time.get_ticks_msec()) - rewind_ms
		for tp in players_by_peer.keys():
			if tp == peer_id:
				continue
			var pnode: Node = players_by_peer[tp]
			if pnode == null or not is_instance_valid(pnode):
				continue
			var sample = lag_comp.sample_at(tp, rewind_to_ms)
			if sample == null:
				continue
			saved_positions[tp] = {"pos": pnode.global_position, "yaw": pnode.rotation.y, "pitch": pnode.head.rotation.x}
			pnode.global_position = sample.pos
			pnode.rotation.y = sample.yaw
			pnode.head.rotation.x = sample.pitch
			# Codex 12:39 P1: PhysicsServer3D doesn't auto-resync Area3D
			# broadphase entries when their global_position is written from
			# script; same-tick raycasts will see the OLD hitbox AABB. Push
			# the new transform for the target's body AND both hitbox areas
			# so intersect_ray below sees the rewound silhouette. Skipping
			# this is why the experimental lag_comp_integration test
			# flickered between hit/miss in a single tick.
			PhysicsServer3D.body_set_state(pnode.get_rid(),
				PhysicsServer3D.BODY_STATE_TRANSFORM, pnode.global_transform)
			if "head_hitbox" in pnode and pnode.head_hitbox != null:
				PhysicsServer3D.area_set_transform(pnode.head_hitbox.get_rid(),
					pnode.head_hitbox.global_transform)
			if "body_hitbox" in pnode and pnode.body_hitbox != null:
				PhysicsServer3D.area_set_transform(pnode.body_hitbox.get_rid(),
					pnode.body_hitbox.global_transform)
		# Shooter's own physics state (kept for the aim-spoof a few lines up).
		PhysicsServer3D.body_set_state(shooter.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, shooter.global_transform)

	var origin: Vector3 = shooter.camera.global_position
	var dir: Vector3 = -shooter.camera.global_transform.basis.z
	var max_dist: float = 500.0 if weapon.is_hitscan() else 200.0
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * max_dist)
	query.collision_mask = _SHOOT_MASK_SERVER
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var ex: Array[RID] = [shooter.get_rid(), shooter.head_hitbox.get_rid(), shooter.body_hitbox.get_rid()]
	query.exclude = ex

	var hit: Dictionary = space.intersect_ray(query)
	if is_dedicated_server:
		if hit.is_empty():
			print("[server]   ↳ ray from=%s dir=%s MISSED" % [str(origin.snapped(Vector3(0.01,0.01,0.01))), str(dir.snapped(Vector3(0.001,0.001,0.001)))])
		else:
			print("[server]   ↳ ray hit %s (%s)" % [hit.collider.name, hit.collider.get_class()])

	# Restore rewound players regardless of hit/miss. Also re-push physics
	# transforms so other systems (collisions, area enter/exit, the very
	# next raycast on a different fire RPC the same tick) see the present
	# position rather than the lingering rewound one.
	for tp in saved_positions.keys():
		var pnode2: Node = players_by_peer.get(tp)
		if pnode2 == null or not is_instance_valid(pnode2):
			continue
		var saved: Dictionary = saved_positions[tp]
		pnode2.global_position = saved["pos"]
		pnode2.rotation.y = saved["yaw"]
		pnode2.head.rotation.x = saved["pitch"]
		PhysicsServer3D.body_set_state(pnode2.get_rid(),
			PhysicsServer3D.BODY_STATE_TRANSFORM, pnode2.global_transform)
		if "head_hitbox" in pnode2 and pnode2.head_hitbox != null:
			PhysicsServer3D.area_set_transform(pnode2.head_hitbox.get_rid(),
				pnode2.head_hitbox.global_transform)
		if "body_hitbox" in pnode2 and pnode2.body_hitbox != null:
			PhysicsServer3D.area_set_transform(pnode2.body_hitbox.get_rid(),
				pnode2.body_hitbox.global_transform)
	# Restore the shooter's pre-fire aim too — we only spoofed it for the ray.
	if not saved_shooter_aim.is_empty():
		shooter.rotation.y = saved_shooter_aim["yaw"]
		shooter.head.rotation.x = saved_shooter_aim["pitch"]

	if hit.is_empty():
		return
	var collider: Node = hit.collider
	if collider == null:
		return
	# Hitbox path: every damageable thing tags its hitboxes with owner_player.
	# That can be a PlayerController (broadcast HP via server_apply_damage) or
	# a DummyTarget (server-only state, take_hit signal observed locally).
	if collider.has_meta(&"owner_player"):
		var victim: Node = collider.get_meta(&"owner_player")
		if victim == null or not is_instance_valid(victim):
			return
		var is_head: bool = collider.get_meta(&"is_head", false)
		if victim is PlayerController:
			if victim.is_dead:
				return
			var dmg: float = PlayerController._compute_damage(weapon, is_head)
			var victim_peer: int = victim.get_multiplayer_authority()
			var hp_before: float = victim.hp
			victim.apply_damage(dmg, shooter)
			# test.md Bug B: read AUTHORITATIVE post-damage HP rather than the
			# pre-computed `victim.hp - dmg`. If apply_damage rejected the hit
			# (typically the 2.5s post-respawn i-frame, or victim_is_dead from a
			# concurrent kill shot), HP is unchanged. Broadcasting the fake
			# reduction would let every client decrement HP and potentially
			# fake a death animation for a still-alive victim — kid reported
			# "刚复活就立刻又被弹回死亡画面".
			var new_hp: float = victim.hp
			if new_hp == hp_before:
				if is_dedicated_server:
					print("[server]   ↳ absorbed: victim %d in i-frame or dead" % victim_peer)
				return
			if is_dedicated_server:
				print("[server] hit: shooter=%d victim=%d dmg=%.1f head=%s new_hp=%.1f hitbox=%s" % [peer_id, victim_peer, dmg, is_head, new_hp, collider.name])
			var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
			if net_rpc != null:
				net_rpc.server_apply_damage.rpc(victim_peer, new_hp, peer_id, weapon_id, is_head)
			# Death broadcast happens in _on_any_player_died now (R1 fix):
			# damage_zone / admin nuke / scripted test kills all funnel
			# through the `died` signal, so the broadcast belongs in the
			# central listener — not duplicated per damage source.
			return
		# Non-player damageable (e.g. DummyTarget). Use whichever entrypoint
		# the target exposes.
		if victim.has_method(&"take_hit"):
			victim.take_hit(weapon, is_head, shooter)
		elif victim.has_method(&"apply_damage"):
			var dmg2: float = PlayerController._compute_damage(weapon, is_head)
			victim.apply_damage(dmg2, shooter)
		return
	# Static collider with a direct take_hit (rare; defensive).
	if collider.has_method(&"take_hit"):
		var is_head_d: bool = collider.name == &"HeadHitbox" or collider.get_meta(&"is_head", false)
		collider.take_hit(weapon, is_head_d, shooter)
		return


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
	if match_controller != null:
		match_controller.record_kill(killer_peer, victim_peer)

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
			net_rpc.server_player_died.rpc(victim_peer, killer_peer, &"", false)

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
		net_rpc.server_player_respawned.rpc(victim_peer, pos)
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


func _on_match_ended(winner: int, final: Dictionary) -> void:
	if hud != null:
		hud.push_feed("MATCH OVER — winner peer %d" % winner, Color(1.0, 0.85, 0.2))
	# Dedicated server doesn't show end-of-match UI; just log + reset.
	if is_dedicated_server:
		print("[server] match ended — winner peer %d" % winner)
		return
	# Pop up the themed end-of-match scoreboard.
	var screen: Node = MATCH_END_SCENE.instantiate()
	add_child(screen)
	var my_id: int = multiplayer.get_unique_id() if _is_networked() else 1
	screen.show_for(winner, final, my_id)
	# Release the cursor so the user can click "Return / Play again".
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
