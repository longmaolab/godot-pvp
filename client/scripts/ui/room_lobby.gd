extends Control
class_name RoomLobbyScene
## Phase 1 room lobby — the screen between "joined a room" and
## "match started". Shows the room's current state (id / map / mode /
## player list) and gives the host a START MATCH button. Joiners see
## the same info minus the START.
##
## Per .agent/lobby_plan.md Phase 1 lock:
##   - No host-changes-map mid-lobby (host picked at create_room time)
##   - No ready states / chat (Phase 2)
##   - Host leaves → room destroyed → everyone evicted to browser
##   - Match end (M3 work) → return here from game scene
##
## The match-start trigger lives in M2 — START sends a new
## `client_start_match` RPC, server begins the match for this room
## while keeping other rooms in LOBBY. M1 just emits a placeholder
## status message.

const ROOM_BROWSER_SCENE := "res://client/scenes/ui/room_browser.tscn"
const MAIN_MENU_SCENE := "res://client/scenes/main_menu.tscn"
const GAME_SCENE := "res://client/scenes/game.tscn"

@onready var room_id_label: Label = $Center/Panel/V/RoomIdLabel
@onready var map_label: Label = $Center/Panel/V/MapLabel
@onready var player_list: ItemList = $Center/Panel/V/PlayerList
@onready var start_btn: Button = $Center/Panel/V/Buttons/StartButton
@onready var ready_btn: Button = $Center/Panel/V/Buttons/ReadyButton
@onready var leave_btn: Button = $Center/Panel/V/Buttons/LeaveButton
@onready var status_label: Label = $Center/Panel/V/StatusLabel

const SKIN_LETTERS := "ABCDEFGHIJKLMNOPQR"   # mirrors PlayerController

var _room_id: String = ""
var _host_peer: int = -1
var _my_peer: int = -1
var _is_host: bool = false
# Track our local optimistic ready state separately so the toggle button's
# pressed visual matches what we just told the server, even before the
# round-trip room_state broadcast lands. Reset on _ready / scene swap.
var _my_ready: bool = false


func _ready() -> void:
	_my_peer = multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 0

	# Pick up the initial room state stashed by room_browser before
	# change_scene_to_file. Settings autoload is the cross-scene channel.
	var initial_state: Dictionary = {}
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		if "pending_room_state" in s:
			initial_state = s.pending_room_state.duplicate() if s.pending_room_state is Dictionary else {}
			s.pending_room_state = {}   # consumed

	leave_btn.pressed.connect(_on_leave_pressed)
	start_btn.pressed.connect(_on_start_pressed)
	ready_btn.toggled.connect(_on_ready_toggled)
	# Default — start_btn/ready_btn visibility is controlled by _apply_room_state
	# once we know who the host is.
	start_btn.visible = false
	ready_btn.visible = false

	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.server_room_state_received.connect(_on_room_state)
		net_rpc.server_room_destroyed_received.connect(_on_room_destroyed)
		net_rpc.server_match_starting_received.connect(_on_match_starting)
	# Connection drops still possible.
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	# Push our local identity to the server so other players see our name
	# + skin instead of "Player <peer_id>". Fire-and-forget — the eventual
	# server_room_state broadcast will reflect it.
	_send_my_profile()

	# Render the initial state we were handed.
	if not initial_state.is_empty():
		_apply_room_state(initial_state)
	else:
		status_label.text = "等待房间数据..."


func _send_my_profile() -> void:
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		return
	var name: String = "Player %d" % _my_peer
	var skin: int = 0
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		if "player_name" in s and not String(s.player_name).is_empty():
			name = String(s.player_name)
		if "skin_index" in s:
			skin = int(s.skin_index)
	net_rpc.client_set_lobby_profile.rpc_id(1, name, skin)


# ── State updates ────────────────────────────────────────────────────────

func _apply_room_state(state: Dictionary) -> void:
	_room_id = String(state.get("id", _room_id))
	_host_peer = int(state.get("host", _host_peer))
	_is_host = (_my_peer == _host_peer)

	room_id_label.text = "房间 %s" % _room_id
	var map_path: String = state.get("map", "")
	var mode_path: String = state.get("mode", "")
	map_label.text = "📍  %s   🎯  %s" % [_short(map_path) if not map_path.is_empty() else "(默认)",
		_short(mode_path) if not mode_path.is_empty() else "(无模式)"]

	# Refresh player list. Each row shows skin letter + name + role badge.
	# Profiles dict may have int OR string keys depending on serialization
	# path (RPC layer sometimes coerces); look up via both to be safe.
	player_list.clear()
	var players: Array = state.get("players", [])
	var profiles: Dictionary = state.get("profiles", {})
	var ready_count: int = 0
	var joiner_count: int = 0
	for peer in players:
		var peer_int: int = int(peer)
		var prof: Dictionary = _lookup_profile(profiles, peer_int)
		var skin_idx: int = clampi(int(prof.get("skin", 0)), 0, SKIN_LETTERS.length() - 1)
		var skin_letter: String = SKIN_LETTERS.substr(skin_idx, 1)
		var raw_name: String = String(prof.get("name", ""))
		# `display_name` not `name` — Node has a `name` property; shadowing
		# it spams GDScript::reload warnings.
		var display_name: String = raw_name if not raw_name.is_empty() else "Player %d" % peer_int
		if peer_int == _my_peer:
			display_name = "%s (你)" % display_name
		var role_badge: String = ""
		if peer_int == _host_peer:
			role_badge = "👑 房主"
		elif bool(prof.get("ready", false)):
			role_badge = "✅ READY"
			ready_count += 1
		else:
			role_badge = "⏳ 等待"
		if peer_int != _host_peer:
			joiner_count += 1
		player_list.add_item("[%s]  %-16s  %s" % [skin_letter, display_name, role_badge])

	# START is host-only. Phase 1 = solo START allowed (1 player is OK).
	start_btn.visible = _is_host
	start_btn.disabled = false
	# READY toggle is for joiners only. Sync its pressed visual to whatever
	# the server believes our state is — guards against the room_state
	# broadcast disagreeing with our local optimistic toggle.
	ready_btn.visible = not _is_host
	var my_prof: Dictionary = _lookup_profile(profiles, _my_peer)
	_my_ready = bool(my_prof.get("ready", false))
	# set_pressed_no_signal so the toggled signal doesn't re-fire while we
	# sync the visual state to what the server told us.
	ready_btn.set_pressed_no_signal(_my_ready)
	ready_btn.text = "✅  已准备 / READY" if _my_ready else "⏳  READY 我准备好了"

	if _is_host:
		if joiner_count == 0:
			status_label.text = "你一个人 — 可以单机 START，或等朋友加入"
		else:
			status_label.text = "可以 START · %d/%d 个玩家已准备" % [ready_count, joiner_count]
	else:
		status_label.text = "等房主点 START" if _my_ready else "标记 READY 让房主知道你准备好了"


## Profile dict may arrive with int OR string keys depending on whether the
## RPC payload went through JSON coercion. Try both.
func _lookup_profile(profiles: Dictionary, peer_id: int) -> Dictionary:
	if profiles.has(peer_id):
		return profiles[peer_id]
	var s_key: String = str(peer_id)
	if profiles.has(s_key):
		return profiles[s_key]
	return {"name": "", "skin": 0, "ready": false}


func _on_room_state(state: Dictionary) -> void:
	# Only apply if the broadcast is for OUR room (defensive — the server
	# already scopes via rpc_id, but a stale message during scene transit
	# shouldn't blow us up).
	if String(state.get("id", "")) != _room_id and not _room_id.is_empty():
		return
	_apply_room_state(state)


func _on_room_destroyed(room_id: String) -> void:
	# Our room was destroyed (host left). Back to browser.
	if room_id != _room_id and not _room_id.is_empty():
		return
	status_label.text = "房间已解散，返回房间列表..."
	# Tiny defer so the player sees the message before the scene swap.
	await get_tree().create_timer(0.8).timeout
	get_tree().change_scene_to_file(ROOM_BROWSER_SCENE)


func _on_match_starting() -> void:
	# M2: server has booted the match for this room — load the game scene.
	# The multiplayer peer persists across change_scene_to_file, so the
	# game scene's _enter_client_mode picks up where we left off.
	status_label.text = "▶ 进入对局..."
	start_btn.disabled = true
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_server_disconnected() -> void:
	push_warning("[room_lobby] server disconnected")
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# ── User actions ─────────────────────────────────────────────────────────

func _on_leave_pressed() -> void:
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.client_leave_room.rpc_id(1)
	# Don't wait for server_room_destroyed (that only fires if I was host).
	# Move back to browser immediately; if the disconnect lags, the
	# browser handles its own re-list.
	get_tree().change_scene_to_file(ROOM_BROWSER_SCENE)


func _on_ready_toggled(pressed: bool) -> void:
	if _is_host:
		return   # host doesn't have a ready bit — implicit always-ready
	_my_ready = pressed
	ready_btn.text = "✅  已准备 / READY" if pressed else "⏳  READY 我准备好了"
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.client_set_ready.rpc_id(1, pressed)


func _on_start_pressed() -> void:
	if not _is_host:
		return
	# M2: send the new client_start_match RPC. Server's RoomManager
	# handler validates host + single-active-match, flips room.state to
	# MATCH, GameController boots the world, server_match_starting fires
	# back to all room players → _on_match_starting above does the scene
	# transition. Disable START in the meantime so a double-click can't
	# fire twice.
	start_btn.disabled = true
	status_label.text = "▶ 启动对局中..."
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.client_start_match.rpc_id(1)


# ── Helpers ──────────────────────────────────────────────────────────────

func _short(path: String) -> String:
	return path.get_file().get_basename()
