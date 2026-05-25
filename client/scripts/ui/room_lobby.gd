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

@onready var room_id_label: Label = $Center/Panel/V/RoomIdLabel
@onready var map_label: Label = $Center/Panel/V/MapLabel
@onready var player_list: ItemList = $Center/Panel/V/PlayerList
@onready var start_btn: Button = $Center/Panel/V/Buttons/StartButton
@onready var leave_btn: Button = $Center/Panel/V/Buttons/LeaveButton
@onready var status_label: Label = $Center/Panel/V/StatusLabel

var _room_id: String = ""
var _host_peer: int = -1
var _my_peer: int = -1
var _is_host: bool = false


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
	# Default — start_btn visibility is controlled by _apply_room_state once
	# we know who the host is.
	start_btn.visible = false

	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.server_room_state_received.connect(_on_room_state)
		net_rpc.server_room_destroyed_received.connect(_on_room_destroyed)
		net_rpc.server_match_starting_received.connect(_on_match_starting)
	# Connection drops still possible.
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	# Render the initial state we were handed.
	if not initial_state.is_empty():
		_apply_room_state(initial_state)
	else:
		status_label.text = "等待房间数据..."


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

	# Refresh player list.
	player_list.clear()
	var players: Array = state.get("players", [])
	for peer in players:
		var tag: String = "👑 " if int(peer) == _host_peer else "👤 "
		var name: String = "你" if int(peer) == _my_peer else "Player %d" % int(peer)
		player_list.add_item("%s%s" % [tag, name])

	# START is host-only. Phase 1 = solo START allowed (1 player is OK).
	start_btn.visible = _is_host
	start_btn.disabled = false
	status_label.text = "等房主点 START" if not _is_host else "可以 START 了"


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
	# M2 will hook this into the actual game scene transition. For M1 we
	# just acknowledge so the user knows START was registered.
	status_label.text = "▶ 对局开始 (M2 工作中)"
	start_btn.disabled = true


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


func _on_start_pressed() -> void:
	if not _is_host:
		return
	# Phase 1 = reuse the existing server_match_starting RPC. M2 work will
	# replace this with a server-side `client_start_match` that runs
	# RoomManager.start_match(room_id) + spawns just this room's players.
	# For now, broadcasts to every connected peer — which is wrong for
	# multi-room but acceptable as a stub until M2.
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.server_match_starting.rpc()
	status_label.text = "▶ 开始对局... (M1 stub — M2 will scope to this room)"
	start_btn.disabled = true


# ── Helpers ──────────────────────────────────────────────────────────────

func _short(path: String) -> String:
	return path.get_file().get_basename()
