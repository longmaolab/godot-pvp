extends Control
class_name RoomBrowser
## Phase 1 room browser — the screen a JOIN-to-DS client lands on after
## the handshake (server_mode_info reports is_dedicated=true). Lets the
## user see open rooms, refresh the list, create a new room, or join an
## existing one. Selecting a room and pressing Join transitions to
## room_lobby.tscn (handled by listening for server_room_joined).
##
## Architecture: the screen is a thin viewer over NetRpc signals. It
## sends `client_list_rooms` on _ready + on Refresh, builds the list from
## `server_room_list_received`, and pushes user actions back through
## `client_create_room` / `client_join_room`. The server (RoomManager)
## does the actual work; we just render.

const ROOM_LOBBY_SCENE := "res://client/scenes/ui/room_lobby.tscn"
const MAIN_MENU_SCENE := "res://client/scenes/main_menu.tscn"
const UiStyle = preload("res://client/scripts/ui/ui_style.gd")

@onready var server_label: Label = $Center/Panel/V/ServerLabel
@onready var room_list: ItemList = $Center/Panel/V/RoomList
@onready var status_label: Label = $Center/Panel/V/StatusLabel
@onready var refresh_btn: Button = $Center/Panel/V/Buttons/RefreshButton
@onready var create_btn: Button = $Center/Panel/V/Buttons/CreateButton
@onready var join_btn: Button = $Center/Panel/V/Buttons/JoinButton
@onready var back_btn: Button = $Center/Panel/V/Buttons/BackButton

# Cached list of full room summaries (id/map/mode/count/max/state) — index
# matches the ItemList row order, so we can resolve "user selected row N"
# back to a room_id.
var _rooms: Array = []

# Map/mode the user picked in main_menu — used when this browser sends
# client_create_room. We read from Settings on _ready (caller stores there
# before changing scene, since main_menu's pickers are gone by then).
var _create_map_path: String = "res://shared/scenes/maps/blank.tscn"
var _create_mode_path: String = ""


func _ready() -> void:
	# Pull the map/mode the user had selected when they clicked JOIN — the
	# Settings autoload is the cross-scene handoff channel since main_menu
	# has already freed by the time we run.
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		if "pending_room_map" in s and not String(s.pending_room_map).is_empty():
			_create_map_path = s.pending_room_map
		if "pending_room_mode" in s:
			_create_mode_path = s.pending_room_mode

	# Server URL for the header label (informational).
	var server_url: String = "unknown"
	if multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer.has_method(&"get_url"):
		server_url = String(multiplayer.multiplayer_peer.get_url())
	server_label.text = "Server: %s" % server_url

	# Wire buttons.
	refresh_btn.pressed.connect(_request_refresh)
	create_btn.pressed.connect(_on_create_pressed)
	join_btn.pressed.connect(_on_join_pressed)
	back_btn.pressed.connect(_on_back_pressed)
	room_list.item_selected.connect(_on_room_selected)
	room_list.item_activated.connect(func(idx): _on_room_selected(idx); _on_join_pressed())
	join_btn.disabled = true   # enable when a row is selected
	# Shared design system: readable list rows + variant-styled buttons.
	UiStyle.style_list(room_list)
	UiStyle.style_button(create_btn, "primary")
	UiStyle.style_button(join_btn, "primary")
	UiStyle.style_button(refresh_btn, "neutral")
	UiStyle.style_button(back_btn, "neutral")

	# Subscribe to RPC replies.
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.server_room_list_received.connect(_on_room_list)
		net_rpc.server_room_joined_received.connect(_on_room_joined)
		net_rpc.server_room_join_failed_received.connect(_on_room_join_failed)
		net_rpc.server_room_destroyed_received.connect(_on_room_destroyed)

	# Handle the server going away (we lose our connection → back to menu).
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	_request_refresh()


# ── User actions ─────────────────────────────────────────────────────────

func _request_refresh() -> void:
	# Skip if we have no real connection (unit tests instantiate this
	# scene without one — the rpc_id(1) below errors with "RPC on yourself
	# not allowed" in that case). Production always has a DS connection
	# by the time we reach this screen.
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		status_label.text = "(无服务器连接)"
		return
	status_label.text = "刷新中..."
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.client_list_rooms.rpc_id(1)


func _on_create_pressed() -> void:
	status_label.text = "创建房间中..."
	create_btn.disabled = true
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.client_create_room.rpc_id(1, _create_map_path, _create_mode_path)


func _on_join_pressed() -> void:
	var idx: int = room_list.get_selected_items()[0] if room_list.get_selected_items().size() > 0 else -1
	if idx < 0 or idx >= _rooms.size():
		return
	var room_id: String = _rooms[idx].get("id", "")
	if room_id.is_empty():
		return
	status_label.text = "加入 %s 中..." % room_id
	join_btn.disabled = true
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.client_join_room.rpc_id(1, room_id)


func _on_back_pressed() -> void:
	# Disconnect from the DS + return to the menu. _on_server_disconnected
	# handles the same path if the connection drops on its own.
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	_return_to_menu()


func _on_room_selected(_idx: int) -> void:
	join_btn.disabled = false


# ── Server replies ───────────────────────────────────────────────────────

func _on_room_list(rooms: Array) -> void:
	_rooms = rooms
	room_list.clear()
	if rooms.is_empty():
		status_label.text = "没有公开房间 — 点 CREATE 开一个"
	else:
		status_label.text = "%d 个房间在线" % rooms.size()
	for r in rooms:
		var label: String = "%s · %s · %d/%d" % [
			r.get("id", "????"),
			_map_short_name(r.get("map", "")),
			r.get("count", 0),
			r.get("max", 4),
		]
		room_list.add_item(label)
	join_btn.disabled = true


func _on_room_joined(room_id: String, room_state: Dictionary) -> void:
	# Stash the initial room state so room_lobby can pick it up without a
	# second round-trip.
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		if "pending_room_state" in s:
			s.pending_room_state = room_state
	status_label.text = "已加入 %s — 进入房间..." % room_id
	get_tree().change_scene_to_file(ROOM_LOBBY_SCENE)


func _on_room_join_failed(reason: String) -> void:
	status_label.text = "❌ 加入失败：%s" % reason
	create_btn.disabled = false
	# Re-fetch the list — the room we tried might've filled up between
	# the list snapshot and our join attempt.
	_request_refresh()


func _on_room_destroyed(room_id: String) -> void:
	# A room in our cached list got destroyed → refresh.
	for r in _rooms:
		if r.get("id", "") == room_id:
			_request_refresh()
			return


func _on_server_disconnected() -> void:
	push_warning("[room_browser] server disconnected — returning to menu")
	_return_to_menu()


# ── Helpers ──────────────────────────────────────────────────────────────

func _return_to_menu() -> void:
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# "res://shared/scenes/maps/koth.tscn" → "koth"
func _map_short_name(path: String) -> String:
	if path.is_empty():
		return "(default)"
	return path.get_file().get_basename()
