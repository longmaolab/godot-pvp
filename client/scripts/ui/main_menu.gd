extends Control
class_name MainMenu

const GAME_SCENE := preload("res://client/scenes/game.tscn")
# P1-14: weapon-catalog card rendering extracted here (pure UI, no menu state).
const _WeaponsDialogBuilder := preload("res://client/scripts/ui/weapons_dialog_builder.gd")
# Runtime-loaded (not preload) to avoid a circular dependency with shop.tscn,
# which preloads main_menu.tscn for its back button.
const SHOP_SCENE_PATH := "res://client/scenes/shop.tscn"

# Map metadata moved to shared/data/map_registry.gd so room_lobby can also
# read it without duplicating the description text. Can't `const = ` an
# external class_name reference (not constexpr), so use a var initialized
# at script load.
var MAPS: Array = MapRegistry.MAPS

const MODES_DIR := "res://shared/data/modes/"

# Built at _ready() by scanning MODES_DIR — same data-driven pattern as the
# weapon registry. Practice (no mode_def) is always first.
var MODES: Array = []

@onready var map_picker: OptionButton = $Scroll/Center/Cols/LeftCard/V/MapPicker
@onready var mode_picker: OptionButton = $Scroll/Center/Cols/LeftCard/V/ModePicker
@onready var map_desc: Label = $Scroll/Center/Cols/LeftCard/V/MapDescription
@onready var mode_desc: Label = $Scroll/Center/Cols/LeftCard/V/ModeDescription
@onready var loadout_picker: OptionButton = $Scroll/Center/Cols/LeftCard/V/LoadoutPicker
@onready var loadout_desc: Label = $Scroll/Center/Cols/LeftCard/V/LoadoutDescription
@onready var loadout_edit_btn: Button = $Scroll/Center/Cols/LeftCard/V/LoadoutEditButton
@onready var loadout_edit_dialog: AcceptDialog = $LoadoutEditDialog
@onready var loadout_edit_slot1: OptionButton = $LoadoutEditDialog/V/Slot1Row/Picker
@onready var loadout_edit_slot2: OptionButton = $LoadoutEditDialog/V/Slot2Row/Picker
@onready var loadout_edit_slot3: OptionButton = $LoadoutEditDialog/V/Slot3Row/Picker
@onready var loadout_edit_slot4: OptionButton = $LoadoutEditDialog/V/Slot4Row/Picker
@onready var loadout_edit_save: Button = $LoadoutEditDialog/V/ButtonsRow/SaveButton
@onready var loadout_edit_reset: Button = $LoadoutEditDialog/V/ButtonsRow/ResetButton
@onready var loadout_edit_status: Label = $LoadoutEditDialog/V/Status
@onready var weapons_btn: Button = $Scroll/Center/Cols/LeftCard/V/WeaponsButton
@onready var shop_btn: Button = $Scroll/Center/Cols/LeftCard/V/ShopButton
@onready var redeem_btn: Button = $Scroll/Center/Cols/LeftCard/V/RedeemButton
@onready var redeem_dialog: AcceptDialog = $RedeemDialog
@onready var redeem_input: LineEdit = $RedeemDialog/V/Input
@onready var redeem_submit: Button = $RedeemDialog/V/SubmitButton
@onready var redeem_status: Label = $RedeemDialog/V/Status
@onready var wheel_btn: Button = $Scroll/Center/Cols/LeftCard/V/WheelButton
@onready var wheel_dialog: AcceptDialog = $WheelDialog
@onready var wheel_spin: Button = $WheelDialog/V/SpinButton
@onready var wheel_result: Label = $WheelDialog/V/Result
@onready var login_btn: Button = $Scroll/Center/Cols/LeftCard/V/LoginButton
@onready var login_dialog: AcceptDialog = $LoginDialog
@onready var login_handle: LineEdit = $LoginDialog/V/HandleRow/HandleInput
@onready var login_password: LineEdit = $LoginDialog/V/PasswordRow/PasswordInput
@onready var login_register_btn: Button = $LoginDialog/V/ButtonsRow/RegisterButton
@onready var login_login_btn: Button = $LoginDialog/V/ButtonsRow/LoginButton
@onready var login_status: Label = $LoginDialog/V/Status
@onready var practice_btn: Button = $Scroll/Center/Cols/RightCard/V/PracticeButton
@onready var create_room_btn: Button = $Scroll/Center/Cols/RightCard/V/CreateRoomButton
@onready var browse_rooms_btn: Button = $Scroll/Center/Cols/RightCard/V/BrowseRoomsButton
@onready var room_code_input: LineEdit = $Scroll/Center/Cols/RightCard/V/RoomCodeRow/RoomCodeInput
@onready var join_by_code_btn: Button = $Scroll/Center/Cols/RightCard/V/RoomCodeRow/JoinByCodeButton
@onready var host_btn: Button = $Scroll/Center/Cols/RightCard/V/HostButton
@onready var join_btn: Button = $Scroll/Center/Cols/RightCard/V/JoinButton
@onready var join_address: LineEdit = $Scroll/Center/Cols/RightCard/V/JoinAddress
@onready var status_label: Label = $Scroll/Center/Cols/RightCard/V/StatusLabel
@onready var stat_weapons: Label = $Scroll/Center/Cols/RightCard/V/StatsRow/StatWeapons/StatWeaponsLabel
@onready var stat_modes: Label = $Scroll/Center/Cols/RightCard/V/StatsRow/StatModes/StatModesLabel
@onready var stat_maps: Label = $Scroll/Center/Cols/RightCard/V/StatsRow/StatMaps/StatMapsLabel
@onready var weapons_dialog: AcceptDialog = $WeaponsDialog
@onready var weapons_list: VBoxContainer = $WeaponsDialog/Scroll/V
@onready var name_input: LineEdit = $Scroll/Center/Cols/LeftCard/V/NameRow/NameInput
@onready var skin_name_label: Label = $Scroll/Center/Cols/LeftCard/V/SkinRow/SkinName
@onready var skin_prev_btn: Button = $Scroll/Center/Cols/LeftCard/V/SkinRow/SkinPrev
@onready var skin_next_btn: Button = $Scroll/Center/Cols/LeftCard/V/SkinRow/SkinNext
@onready var summary_map: Label = $Scroll/Center/Cols/RightCard/V/SelectionSummary/H/SummaryMap
@onready var summary_mode: Label = $Scroll/Center/Cols/RightCard/V/SelectionSummary/H/SummaryMode
@onready var summary_skin: Label = $Scroll/Center/Cols/RightCard/V/SelectionSummary/H/SummarySkin
# Staging panel — sits between SelectionSummary and PracticeButton in the
# right card. Hidden until HOST or JOIN is pressed; when shown, _enter_staging
# ALSO hides the PRACTICE + MULTIPLAYER section below so the LOBBY view +
# START button is the only thing visible in the action area.
@onready var staging_panel: PanelContainer = $Scroll/Center/Cols/RightCard/V/StagingPanel
@onready var staging_status: Label = $Scroll/Center/Cols/RightCard/V/StagingPanel/V/StagingStatus
@onready var staging_count: Label = $Scroll/Center/Cols/RightCard/V/StagingPanel/V/StagingCount
@onready var start_btn: Button = $Scroll/Center/Cols/RightCard/V/StagingPanel/V/StartButton
@onready var cancel_btn: Button = $Scroll/Center/Cols/RightCard/V/StagingPanel/V/CancelButton
# Things to hide when staging is active so START doesn't get buried below
# a PRACTICE button + a "MULTIPLAYER" section. Collected up front so we
# can flip them together in _enter_staging / _exit_staging.
@onready var _menu_state_nodes: Array[Node] = [
	$Scroll/Center/Cols/RightCard/V/ActionHeader,
	$Scroll/Center/Cols/RightCard/V/PracticeButton,
	$Scroll/Center/Cols/RightCard/V/PracticeHint,
	$Scroll/Center/Cols/RightCard/V/Sep1,
	$Scroll/Center/Cols/RightCard/V/PublicHeader,
	$Scroll/Center/Cols/RightCard/V/PublicHint,
	$Scroll/Center/Cols/RightCard/V/CreateRoomButton,
	$Scroll/Center/Cols/RightCard/V/BrowseRoomsButton,
	$Scroll/Center/Cols/RightCard/V/RoomCodeRow,
	$Scroll/Center/Cols/RightCard/V/SepLan,
	$Scroll/Center/Cols/RightCard/V/LanHeader,
	$Scroll/Center/Cols/RightCard/V/HostButton,
	$Scroll/Center/Cols/RightCard/V/JoinAddrLabel,
	$Scroll/Center/Cols/RightCard/V/JoinAddress,
	$Scroll/Center/Cols/RightCard/V/JoinButton,
]

# When the user clicks JOIN-to-DS via the new flow, this captures whether
# they meant "create a new room" (CREATE button), "browse and pick"
# (BROWSE button), or "join a specific code" (ROOM CODE entry / invite
# link). _on_server_mode_info_for_routing reads it after the DS
# handshake to pick the right next step. Cleared after each consumption.
var _connect_intent: String = "browse"   # "browse" | "create" | "join_code"
# Set alongside _connect_intent = "join_code". Cleared on consumption.
var _pending_room_code: String = ""

# Staging state. _is_staging=false → normal menu; =true → user already
# clicked HOST or JOIN and is waiting in the lobby.
var _is_staging: bool = false
var _is_host: bool = false      # true while staging as the server side
var _peer_count: int = 1        # 1 = us; host increments on peer_connected


func _ready() -> void:
	# Release the mouse if a previous in-game scene left it captured.
	# Without this, returning from game.tscn (via pause-menu MAIN MENU,
	# server disconnect, etc.) keeps Input.mouse_mode = CAPTURED, so the
	# user can't see the cursor or click ANY button on this menu — looks
	# like the menu "froze" the second time they try to launch practice.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var vlabel: Label = get_node_or_null(^"VersionLabel")
	if vlabel != null:
		var bi := preload("res://client/scripts/build_info.gd")
		vlabel.text = "build %s · godot 4.6" % bi.VERSION
	_wire_fun_facts()
	_wire_loadout_picker()
	_build_modes_from_disk()
	practice_btn.pressed.connect(_on_practice)
	create_room_btn.pressed.connect(_on_create_room_pressed)
	browse_rooms_btn.pressed.connect(_on_browse_rooms_pressed)
	join_by_code_btn.pressed.connect(_on_join_by_code_pressed)
	# Submit-on-Enter for the code field so users can type AXJ7 → Return.
	room_code_input.text_submitted.connect(func(_t): _on_join_by_code_pressed())
	host_btn.pressed.connect(_on_host)
	join_btn.pressed.connect(_on_join)
	weapons_btn.pressed.connect(_on_show_weapons)
	shop_btn.pressed.connect(_on_open_shop)
	redeem_btn.pressed.connect(_on_open_redeem)
	redeem_submit.pressed.connect(_on_submit_redeem)
	redeem_input.text_submitted.connect(func(_t): _on_submit_redeem())
	wheel_btn.pressed.connect(_on_open_wheel)
	wheel_spin.pressed.connect(_on_submit_spin)
	login_btn.pressed.connect(_on_open_login)
	login_register_btn.pressed.connect(_on_register_pressed)
	login_login_btn.pressed.connect(_on_login_pressed)
	loadout_edit_btn.pressed.connect(_on_open_loadout_edit)
	loadout_edit_save.pressed.connect(_on_loadout_edit_save)
	loadout_edit_reset.pressed.connect(_on_loadout_edit_reset)
	# Subscribe to Settings.server_action so we can show success/failure
	# feedback inside the redeem dialog. Settings emits this for ALL
	# server-acked actions; we only react when action == "redeem_code".
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		if "server_action" in s and not s.server_action.is_connected(_on_settings_action):
			s.server_action.connect(_on_settings_action)
		if "reward_received" in s and not s.reward_received.is_connected(_on_settings_reward):
			s.reward_received.connect(_on_settings_reward)
	# Staging-panel wiring. Hidden by default in the .tscn — _enter_staging
	# flips it visible. START is host-only; CANCEL tears down whichever
	# peer (server or client) and returns to the normal menu.
	start_btn.pressed.connect(_on_start_match)
	cancel_btn.pressed.connect(_on_cancel_staging)
	# Multiplayer signals — fire on the menu while staging is active. The
	# guards inside the handlers no-op when _is_staging=false so they're
	# safe to leave connected for the menu's lifetime.
	multiplayer.peer_connected.connect(_on_peer_connected_staging)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected_staging)
	multiplayer.connected_to_server.connect(_on_connected_to_host_staging)
	multiplayer.connection_failed.connect(_on_connection_failed_staging)
	multiplayer.server_disconnected.connect(_on_server_disconnected_staging)
	# START broadcast from the host (listen-host LAN mode).
	if has_node(^"/root/NetRpc"):
		var net_rpc: Node = get_node(^"/root/NetRpc")
		if not net_rpc.server_match_starting_received.is_connected(_on_match_starting):
			net_rpc.server_match_starting_received.connect(_on_match_starting)
		# DS-vs-listen-host routing: when we JOIN, the server tells us
		# which mode it's running via server_mode_info. If it's a DS, we
		# don't stay on the staging panel — we route into the room
		# browser (BROWSE intent) or send create_room (CREATE intent).
		if not net_rpc.server_mode_info_received.is_connected(_on_server_mode_info_for_routing):
			net_rpc.server_mode_info_received.connect(_on_server_mode_info_for_routing)
		# CREATE-flow follow-up: when the DS replies with server_room_joined
		# we jump straight into room_lobby. Hooked on the menu (and not just
		# on room_browser) because the browser scene is skipped in the
		# CREATE path entirely.
		if not net_rpc.server_room_joined_received.is_connected(_on_server_room_joined_from_menu):
			net_rpc.server_room_joined_received.connect(_on_server_room_joined_from_menu)
		if not net_rpc.server_room_join_failed_received.is_connected(_on_server_room_join_failed_from_menu):
			net_rpc.server_room_join_failed_received.connect(_on_server_room_join_failed_from_menu)
	# Identity row — wire name + skin to the Settings autoload.
	skin_prev_btn.pressed.connect(_skin_step.bind(-1))
	skin_next_btn.pressed.connect(_skin_step.bind(1))
	name_input.text_changed.connect(_on_name_changed)
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		name_input.text = s.player_name
		_refresh_skin_label()
	# Pre-fill the Join address with whatever ServerDiscovery resolved.
	if has_node(^"/root/ServerDiscovery"):
		var sd: Node = get_node(^"/root/ServerDiscovery")
		join_address.placeholder_text = sd.url
		sd.resolved.connect(func(u: String):
			if join_address.text.is_empty():
				join_address.placeholder_text = u)
	if map_picker != null:
		for m in MAPS:
			map_picker.add_item(m.name)
		map_picker.item_selected.connect(_on_map_changed)
	if mode_picker != null:
		for m in MODES:
			mode_picker.add_item(m.name)
		mode_picker.item_selected.connect(_on_mode_changed)
	_on_map_changed(0)
	# Default to MODES[1] (the first real mode after Practice) rather than
	# MODES[0] = Practice. Reason: MODES[0].path is empty by design — it's
	# the single-player marker. If a user clicks CREATE ROOM without
	# touching the mode picker, an empty mode_def_path lands on the
	# server, which skips match_controller creation and leaves the
	# scoreboard with no kills/deaths to display. Defaulting to a real
	# mode makes the common-case path actually score.
	var default_mode_idx: int = 1 if MODES.size() > 1 else 0
	if mode_picker != null:
		mode_picker.selected = default_mode_idx
	_on_mode_changed(default_mode_idx)
	_populate_weapons_dialog()
	var weapon_count: int = _count_weapons_on_disk()
	# Stat pills along the top of the right card.
	stat_weapons.text = "▣ %d 武器" % weapon_count
	stat_modes.text = "◇ %d 模式" % MODES.size()
	stat_maps.text = "◈ %d 地图" % MAPS.size()
	status_label.text = "M3 vertical slice · server-authoritative · 9 test suites green"
	# Invite-link auto-join: if launched in the browser with ?room=AXJ7
	# in the URL, pre-fill the code field and fire the join flow. Deferred
	# so the multiplayer signal wiring above is fully in place when the
	# connect attempt starts.
	call_deferred("_maybe_auto_join_from_url")


## Invite-link entry path. In the web export, the URL query string is the
## one cross-environment channel a friend can paste into a chat — checking
## `?room=AXJ7` here lets a shared link land the user straight in the
## right lobby instead of asking them to retype the code.
func _maybe_auto_join_from_url() -> void:
	# Same gate arena-shooter-3d uses for its server-discovery JS bridge:
	# OS.has_feature("web") is true in the web export, and the singleton
	# check protects against the rare case where the engine was built
	# without JavaScript support. Both guards together mean this branch
	# never runs on native.
	if not (OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge")):
		return
	var qs_v: Variant = JavaScriptBridge.eval("window.location.search", true)
	if typeof(qs_v) != TYPE_STRING:
		return
	var qs: String = qs_v
	if qs.begins_with("?"):
		qs = qs.substr(1)
	if qs.is_empty():
		return
	var code: String = ""
	for pair in qs.split("&", false):
		var kv: PackedStringArray = pair.split("=", true, 1)
		if kv.size() == 2 and kv[0].to_lower() == "room":
			code = kv[1].strip_edges().to_upper()
			break
	if code.length() != 4:
		return
	room_code_input.text = code
	status_label.text = "邀请链接：%s" % code
	_on_join_by_code_pressed()


func _build_modes_from_disk() -> void:
	MODES = [{"name": "Practice — 单人 vs bot", "path": "", "desc": "单机模式。一个会移动还击的红色 AI bot + 一个站着不动的假人。学操作和试武器最合适。死了 3 秒后自动重生。"}]
	var dir := DirAccess.open(MODES_DIR)
	if dir == null:
		return
	var entries: Array = []
	dir.list_dir_begin()
	while true:
		var fname: String = dir.get_next()
		if fname == "":
			break
		# Web export rewrites every .tres to <name>.tres.remap (a path
		# indirection file — load() against the original .tres path still
		# resolves correctly via the remap, but DirAccess only sees the
		# .remap name). Without this strip the menu shows zero modes in
		# the web build; native runs see real .tres and skip the strip.
		if fname.ends_with(".tres.remap"):
			fname = fname.substr(0, fname.length() - 6)
		if dir.current_is_dir() or fname.begins_with("_") or not fname.ends_with(".tres"):
			continue
		var res: Resource = load(MODES_DIR + fname)
		if res == null:
			continue
		entries.append({
			"name": res.display_name if "display_name" in res and not res.display_name.is_empty() else fname,
			"path": MODES_DIR + fname,
			"desc": res.description if "description" in res else "",
		})
	dir.list_dir_end()
	# Sort by display name so the picker order is stable.
	entries.sort_custom(func(a, b): return a.name < b.name)
	MODES.append_array(entries)


func _skin_step(direction: int) -> void:
	if not has_node(^"/root/Settings"):
		return
	var s: Node = get_node(^"/root/Settings")
	var new_idx: int = (s.skin_index + direction + 18) % 18
	s.set_skin(new_idx)
	_refresh_skin_label()


func _refresh_skin_label() -> void:
	if not has_node(^"/root/Settings"):
		return
	var s: Node = get_node(^"/root/Settings")
	# A..R letter mapping mirrors PlayerController.SKIN_LETTERS.
	var letter: String = "ABCDEFGHIJKLMNOPQR".substr(s.skin_index, 1)
	skin_name_label.text = "Character %s (%d / 18)" % [letter, s.skin_index + 1]
	_refresh_summary()


## Mirror the current left-side selections (map / mode / skin) into the
## right-card "you're about to play" pill, so picks visibly affect both
## halves of the screen instead of just updating a small description label.
func _refresh_summary() -> void:
	if summary_map != null and map_picker != null:
		var midx: int = clampi(map_picker.selected, 0, MAPS.size() - 1)
		summary_map.text = "@ %s" % MAPS[midx].name
	if summary_mode != null and mode_picker != null and MODES.size() > 0:
		var oidx: int = clampi(mode_picker.selected, 0, MODES.size() - 1)
		summary_mode.text = "* %s" % MODES[oidx].name
	if summary_skin != null and has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		var letter: String = "ABCDEFGHIJKLMNOPQR".substr(s.skin_index, 1)
		summary_skin.text = "Character %s" % letter


func _on_name_changed(new_text: String) -> void:
	if has_node(^"/root/Settings"):
		get_node(^"/root/Settings").set_player_name(new_text)


func _count_weapons_on_disk() -> int:
	var dir := DirAccess.open("res://shared/data/weapons/")
	if dir == null:
		return 0
	var n: int = 0
	dir.list_dir_begin()
	while true:
		var fname: String = dir.get_next()
		if fname == "":
			break
		# .tres.remap strip — see comment in _build_modes_from_disk.
		if fname.ends_with(".tres.remap"):
			fname = fname.substr(0, fname.length() - 6)
		if dir.current_is_dir() or fname.begins_with("_") or not fname.ends_with(".tres"):
			continue
		n += 1
	dir.list_dir_end()
	return n


func _on_map_changed(idx: int) -> void:
	idx = clampi(idx, 0, MAPS.size() - 1)
	map_desc.text = MAPS[idx].desc
	_refresh_summary()


func _on_mode_changed(idx: int) -> void:
	idx = clampi(idx, 0, MODES.size() - 1)
	# Prefer the .tres's own description if available so we have one source of truth.
	var path: String = MODES[idx].path
	if path != "" and ResourceLoader.exists(path):
		var mode_res: Resource = load(path)
		if mode_res != null and "description" in mode_res and not mode_res.description.is_empty():
			mode_desc.text = mode_res.description
			_refresh_summary()
			return
	mode_desc.text = MODES[idx].desc
	_refresh_summary()


func _on_show_weapons() -> void:
	weapons_dialog.popup_centered(Vector2i(640, 480))


func _on_open_shop() -> void:
	var s: PackedScene = load(SHOP_SCENE_PATH)
	if s != null:
		get_tree().change_scene_to_packed(s)


func _populate_weapons_dialog() -> void:
	# P1-14: card rendering lives in WeaponsDialogBuilder (pure UI, no menu
	# state). We pass _on_apply_upgrade as the upgrade-button action so the
	# builder stays decoupled from networking / Settings.
	_WeaponsDialogBuilder.populate(weapons_list, get_node_or_null(^"/root/Settings"), _on_apply_upgrade)


func _on_apply_upgrade(weapon_id: String, stat: String, target_level: int) -> void:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		# Offline — show a popup hint via WeaponsDialog title; full UI would
		# need an inline status row but the catalog scrolls a lot already.
		weapons_dialog.title = "武器图鉴 — 升级需先 CREATE ROOM / BROWSE 连服务器"
		return
	var settings: Node = get_node_or_null(^"/root/Settings")
	if settings == null or not settings.has_method(&"request_apply_upgrade"):
		return
	settings.request_apply_upgrade(weapon_id, stat, target_level)
	# Re-populate on next open — refresh comes via _on_settings_action ("upgrade").
	weapons_dialog.title = "武器图鉴 — 升级提交中..."


func _make_badge(text: String, color: Color) -> PanelContainer:
	var pc := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(color.r * 0.25, color.g * 0.25, color.b * 0.25, 0.85)
	s.border_color = color
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.corner_radius_top_left = 4
	s.corner_radius_top_right = 4
	s.corner_radius_bottom_left = 4
	s.corner_radius_bottom_right = 4
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 2
	s.content_margin_bottom = 2
	pc.add_theme_stylebox_override(&"panel", s)
	var l := Label.new()
	l.text = text
	l.add_theme_color_override(&"font_color", color)
	l.add_theme_font_size_override(&"font_size", 11)
	pc.add_child(l)
	return pc


func _make_stat_bar(label: String, value: int, min_v: int, max_v: int, color: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 8)
	row.custom_minimum_size = Vector2(310, 0)

	var name_lbl := Label.new()
	name_lbl.text = label
	name_lbl.custom_minimum_size = Vector2(48, 0)
	name_lbl.add_theme_font_size_override(&"font_size", 11)
	name_lbl.add_theme_color_override(&"font_color", Color(0.55, 0.78, 0.95, 0.85))
	row.add_child(name_lbl)

	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(180, 12)
	bar.min_value = min_v
	bar.max_value = max_v
	bar.value = clamp(value, min_v, max_v)
	bar.show_percentage = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.04, 0.07, 0.13, 1)
	bg.border_color = Color(0.3, 0.55, 0.85, 0.4)
	bg.border_width_left = 1
	bg.border_width_right = 1
	bg.border_width_top = 1
	bg.border_width_bottom = 1
	bg.corner_radius_top_left = 4
	bg.corner_radius_top_right = 4
	bg.corner_radius_bottom_left = 4
	bg.corner_radius_bottom_right = 4
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.corner_radius_top_left = 3
	fill.corner_radius_top_right = 3
	fill.corner_radius_bottom_left = 3
	fill.corner_radius_bottom_right = 3
	bar.add_theme_stylebox_override(&"background", bg)
	bar.add_theme_stylebox_override(&"fill", fill)
	row.add_child(bar)

	var val_lbl := Label.new()
	val_lbl.text = "%d" % value if value < 999 else "∞"
	val_lbl.custom_minimum_size = Vector2(40, 0)
	val_lbl.add_theme_font_size_override(&"font_size", 12)
	val_lbl.add_theme_color_override(&"font_color", color)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val_lbl)

	return row


func _weapon_card_style(wpn: Resource) -> StyleBoxFlat:
	# Highlight admin / instakill weapons with a warmer border so they pop.
	# wpn is typed as Resource (not WeaponDef) so we need an explicit type
	# annotation — GDScript can't infer bullet_color from a base Resource.
	var c: Color = Color(0.5, 0.85, 1, 0.6)
	if "bullet_color" in wpn:
		c = wpn.bullet_color
	c.a = 0.55
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.05, 0.08, 0.15, 0.92)
	s.border_color = c
	s.border_width_left = 2
	s.border_width_top = 2
	s.border_width_right = 2
	s.border_width_bottom = 2
	s.corner_radius_top_left = 10
	s.corner_radius_top_right = 10
	s.corner_radius_bottom_left = 10
	s.corner_radius_bottom_right = 10
	s.shadow_color = Color(0, 0, 0, 0.4)
	s.shadow_size = 6
	return s


func _selected_map_path() -> String:
	if map_picker == null:
		return MAPS[0].path
	var idx: int = clampi(map_picker.selected, 0, MAPS.size() - 1)
	return MAPS[idx].path


func _selected_mode_path() -> String:
	if mode_picker == null:
		return ""
	var idx: int = clampi(mode_picker.selected, 0, MODES.size() - 1)
	return MODES[idx].path


func _on_practice() -> void:
	# Belt-and-suspenders: if the user previously hit HOST / JOIN / CREATE
	# ROOM / BROWSE ROOMS and then backed out without a clean teardown,
	# `multiplayer.multiplayer_peer` can still be a live WebSocket peer.
	# Without this cleanup, game_controller's _ready sees _is_networked()
	# == true and walks the MP enter_host/client path INSTEAD of practice.
	#
	# IMPORTANT: gate on a real peer, not `has_multiplayer_peer()`.
	# Godot's default MultiplayerAPI ships with an OfflineMultiplayerPeer
	# attached, so has_multiplayer_peer() returns true even when there's
	# no networking. Calling .close() on the offline peer then errors
	# silently and _launch_game() is never reached — clicking PRACTICE
	# does nothing. Inspect the peer type and skip the close for offline.
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer != null and not (peer is OfflineMultiplayerPeer):
		peer.close()
		multiplayer.multiplayer_peer = null
	_launch_game()


func _on_host() -> void:
	var peer := WebSocketMultiplayerPeer.new()
	_bump_buffers(peer)
	var err := peer.create_server(7777)
	if err != OK:
		# Most common cause: a dedicated server is already running on 7777.
		status_label.text = "❌ Host 失败 (err=%s) — 端口 7777 被占用？\n如果跑了 ./scripts/start_server.sh 请用 JOIN 而不是 HOST" % err
		return
	multiplayer.multiplayer_peer = peer
	status_label.text = "✅ Hosting on :7777"
	# Stop in the menu's staging panel instead of jumping into the game.
	# Host gets the START button; clients arrive and wait.
	_enter_staging(true)


func _on_join() -> void:
	# Generic JOIN-by-address — could be a DS or a listen-host LAN game.
	# Intent defaults to "browse" so if it's a DS we end up in the room
	# browser (most useful for "type a friend's URL and join their server").
	_connect_intent = "browse"
	_connect_to_server(_resolve_join_address())


## CREATE flow: pick map/mode on the left card, click this, get dropped
## straight into your new room's lobby. Skips the browser entirely.
func _on_create_room_pressed() -> void:
	_connect_intent = "create"
	create_room_btn.disabled = true
	browse_rooms_btn.disabled = true
	_connect_to_server(_default_public_server())


## BROWSE flow: connect to the default public DS, jump to the room
## browser, pick from existing or create from there.
func _on_browse_rooms_pressed() -> void:
	_connect_intent = "browse"
	create_room_btn.disabled = true
	browse_rooms_btn.disabled = true
	_connect_to_server(_default_public_server())


## ROOM CODE flow: friend shared "AXJ7" — connect, send client_join_room
## with that code, skip the browser. Also the auto-join target for the
## web `?room=AXJ7` URL param path (M2 work).
func _on_join_by_code_pressed() -> void:
	var code: String = room_code_input.text.strip_edges().to_upper()
	if code.length() != 4:
		status_label.text = "❌ 房间码要 4 位字母 / 数字"
		return
	_connect_intent = "join_code"
	_pending_room_code = code
	create_room_btn.disabled = true
	browse_rooms_btn.disabled = true
	join_by_code_btn.disabled = true
	_connect_to_server(_default_public_server())


## Single place that creates the client peer + transitions to the staging
## panel "connecting" state. Called by all 3 paths (JOIN-by-address, CREATE,
## BROWSE) so failure handling lives in one spot.
func _connect_to_server(address: String) -> void:
	var peer := WebSocketMultiplayerPeer.new()
	_bump_buffers(peer)
	var err := peer.create_client(address)
	if err != OK:
		status_label.text = "Connect failed: %s" % err
		create_room_btn.disabled = false
		browse_rooms_btn.disabled = false
		return
	multiplayer.multiplayer_peer = peer
	status_label.text = "Connecting to %s..." % address
	_enter_staging(false)


## What URL does CREATE / BROWSE point at? Prefer ServerDiscovery's
## resolved URL (web build reads server.json → production wss); else
## fall back to the local DS default.
func _default_public_server() -> String:
	if has_node(^"/root/ServerDiscovery"):
		var sd: Node = get_node(^"/root/ServerDiscovery")
		if "url" in sd and not String(sd.url).is_empty():
			return sd.url
	return "ws://127.0.0.1:7777"


## JOIN-by-address: use the text the user typed if any, otherwise fall
## back to ServerDiscovery's URL just like CREATE/BROWSE.
func _resolve_join_address() -> String:
	var address: String = join_address.text.strip_edges()
	if not address.is_empty():
		return address
	return _default_public_server()


## Toggle the menu into staging (lobby) mode. Hides the PRACTICE +
## MULTIPLAYER section entirely so the LOBBY pill + START button stand
## alone in the action area. START shows only on the host side.
func _enter_staging(as_host: bool) -> void:
	_is_staging = true
	_is_host = as_host
	_peer_count = 1
	staging_panel.visible = true
	start_btn.visible = as_host
	if as_host:
		staging_status.text = "Hosting on :7777 — 等人加入"
		staging_count.text = "Connected: 1 (you) — 可以直接 START 单人开"
	else:
		staging_status.text = "Connecting to host..."
		staging_count.text = "等房主点 START"
	# Hide every "normal menu" node in the right card so START is the only
	# primary action visible — no more PRACTICE button competing for the
	# eye, no MULTIPLAYER section the user could mistakenly re-click.
	for n in _menu_state_nodes:
		n.visible = false


## Tear down the peer + return to normal menu state. Triggered by
## CANCEL, by connection_failed, or by server_disconnected.
func _exit_staging() -> void:
	_is_staging = false
	_is_host = false
	staging_panel.visible = false
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	# Restore the normal menu nodes.
	for n in _menu_state_nodes:
		n.visible = true
	# Re-enable the public-flow buttons in case CREATE/BROWSE disabled them.
	create_room_btn.disabled = false
	browse_rooms_btn.disabled = false


# ── Staging signal handlers ──────────────────────────────────────────────
func _on_peer_connected_staging(_id: int) -> void:
	if not _is_staging or not _is_host:
		return
	_peer_count += 1
	staging_count.text = "Connected: %d 玩家 (1 host + %d joined) — 可以 START 了" % [_peer_count, _peer_count - 1]


func _on_peer_disconnected_staging(_id: int) -> void:
	if not _is_staging or not _is_host:
		return
	_peer_count = maxi(1, _peer_count - 1)
	if _peer_count <= 1:
		staging_count.text = "Connected: 1 (you) — 可以直接 START 单人开"
	else:
		staging_count.text = "Connected: %d 玩家" % _peer_count


func _on_connected_to_host_staging() -> void:
	if not _is_staging or _is_host:
		return
	staging_status.text = "Connected — 等房主点 START"
	# Send the hello handshake so the server replies with server_mode_info
	# — that's what _on_server_mode_info_for_routing listens for to decide
	# between staying on this staging panel (listen-host) and jumping into
	# room_browser (dedicated server). Without this we sit here forever
	# waiting for an event the server has no reason to emit. game_controller
	# later sends its own hello after the scene transition — the server's
	# handler is idempotent (just re-emits welcome + mode_info).
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		var name_str: String = "Player"
		if has_node(^"/root/Settings"):
			var s: Node = get_node(^"/root/Settings")
			if "player_name" in s and not String(s.player_name).is_empty():
				name_str = s.player_name
		net_rpc.client_hello.rpc_id(1, name_str)
	# Persistence sync (P-M3+): grab the canonical profile snapshot from
	# the DS now that we have a peer. Settings autoload mirrors what
	# comes back, including any progression earned on this device that
	# was lost from local cfg (e.g. browser cache cleared, new device).
	if has_node(^"/root/Settings"):
		var s2: Node = get_node(^"/root/Settings")
		if s2.has_method(&"sync_with_server"):
			s2.call(&"sync_with_server")


func _on_connection_failed_staging() -> void:
	if not _is_staging or _is_host:
		return
	status_label.text = "❌ 连不上服务器"
	_exit_staging()


func _on_server_disconnected_staging() -> void:
	if not _is_staging:
		return
	# If we're the host this fires when our peer goes down — host normally
	# doesn't see it (we tear ourselves down via CANCEL), but defensively
	# handle it the same way.
	status_label.text = "❌ 服务器断开" if not _is_host else "❌ 服务器关闭"
	_exit_staging()


## Host clicked START — broadcast to all clients and launch self into the
## game scene. call_remote on the RPC excludes us, so the local launch
## here is the host's own trip into the game.
func _on_start_match() -> void:
	if not _is_staging or not _is_host:
		return
	if has_node(^"/root/NetRpc"):
		get_node(^"/root/NetRpc").server_match_starting.rpc()
	_launch_game()


## Client received server_match_starting — match has begun.
func _on_match_starting() -> void:
	if not _is_staging or _is_host:
		return  # host already launched in _on_start_match
	_launch_game()


## Decide which way to go after a DS handshake completes. Server replies
## with server_mode_info(is_dedicated=true), and _connect_intent tells us
## which button got us here:
##   "create" → fire client_create_room immediately + wait for joined
##              response (handled in _on_server_room_joined_from_menu).
##   "browse" → transition to the browser scene; user picks from there.
## Listen-host (is_dedicated=false) → stay on the staging panel; the LAN
## flow's HOST clicks START etc.
const ROOM_BROWSER_SCENE := "res://client/scenes/ui/room_browser.tscn"
const ROOM_LOBBY_SCENE := "res://client/scenes/ui/room_lobby.tscn"

func _on_server_mode_info_for_routing(is_dedicated: bool) -> void:
	if not _is_staging or _is_host:
		return  # host doesn't route — host has its own flow; client-only path
	if not is_dedicated:
		return  # listen-host — fall through to existing _on_match_starting flow
	# Stash menu picks for either downstream scene to read via Settings.
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		if "pending_room_map" in s:
			s.pending_room_map = _selected_map_path()
		if "pending_room_mode" in s:
			s.pending_room_mode = _selected_mode_path()
	match _connect_intent:
		"create":
			# Fire create_room immediately. server_room_joined will land in
			# _on_server_room_joined_from_menu which does the scene swap.
			status_label.text = "正在创建房间..."
			var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
			if net_rpc != null:
				net_rpc.client_create_room.rpc_id(1, _selected_map_path(), _selected_mode_path())
		"join_code":
			# Friend's invite code: send client_join_room directly. Same
			# server_room_joined path as create lands us in the lobby.
			status_label.text = "正在加入 %s..." % _pending_room_code
			var nr: Node = get_node_or_null(^"/root/NetRpc")
			if nr != null:
				nr.client_join_room.rpc_id(1, _pending_room_code)
		_:
			# Browse intent (default): into the room list, user picks from there.
			get_tree().change_scene_to_file(ROOM_BROWSER_SCENE)


## CREATE-flow follow-up: server confirmed our room. Stash state for the
## lobby scene + transition. Idempotent against the browser also handling
## this signal — browser does its own change_scene, but it's freed by
## then if we took the CREATE shortcut.
func _on_server_room_joined_from_menu(_room_id: String, room_state: Dictionary) -> void:
	# Both "create" and "join_code" paths funnel through here — the only
	# diff is "did the server make a new room for us or put us into an
	# existing one". UX-wise both end in the same lobby scene.
	if not _is_staging:
		return
	if _connect_intent != "create" and _connect_intent != "join_code":
		return
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		if "pending_room_state" in s:
			s.pending_room_state = room_state.duplicate()
	_pending_room_code = ""   # consumed
	get_tree().change_scene_to_file(ROOM_LOBBY_SCENE)


func _on_server_room_join_failed_from_menu(reason: String) -> void:
	if not _is_staging:
		return
	if _connect_intent != "create" and _connect_intent != "join_code":
		return
	var label: String = "创建房间" if _connect_intent == "create" else "加入 %s" % _pending_room_code
	status_label.text = "❌ %s 失败：%s" % [label, reason]
	# Stay on the menu — user can try again, change settings, or pick a
	# different MP path. Re-enable so they can do that.
	_pending_room_code = ""
	_exit_staging()


func _on_cancel_staging() -> void:
	_exit_staging()
	status_label.text = "已取消"


func _launch_game() -> void:
	# Apply map + mode choices to the game scene before swapping into it.
	var game: Node = GAME_SCENE.instantiate()
	var map_path: String = _selected_map_path()
	if ResourceLoader.exists(map_path):
		game.map_scene = load(map_path)
	var mode_path: String = _selected_mode_path()
	if mode_path != "" and ResourceLoader.exists(mode_path):
		game.mode_def = load(mode_path)
	get_tree().root.add_child(game)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = game


# Bump WebSocket send/recv buffers from the 64KB default to 1MB. Default
# overflows under FPS-rate input streaming + per-hit RPCs — symptoms:
# "Buffer payload full! Dropping data." spam + frozen client (input
# silently dropped, server never hears player). Must be called BEFORE
# create_client / create_server.
func _bump_buffers(peer: WebSocketMultiplayerPeer) -> void:
	peer.outbound_buffer_size = 1 << 20
	peer.inbound_buffer_size = 1 << 20
	peer.max_queued_packets = 8192


# Random gameplay tip in the LeftCard; cycles every 8s. Pure cosmetic /
# onboarding aid — no game-state effect. Safe to skip silently if the
# scene didn't include the FunFact label (older .tscn versions).
const _FUN_FACTS := preload("res://client/scripts/data/fun_facts.gd")
const _BEST_LOADOUTS := preload("res://client/scripts/data/best_loadouts.gd")


func _wire_fun_facts() -> void:
	var fun_label: Label = get_node_or_null(^"Scroll/Center/Cols/LeftCard/V/FunFact")
	if fun_label == null:
		return
	fun_label.text = "▶ TIP — " + _FUN_FACTS.random()
	var tip_timer := Timer.new()
	tip_timer.wait_time = 8.0
	tip_timer.autostart = true
	tip_timer.timeout.connect(
		func():
			if is_instance_valid(fun_label):
				fun_label.text = "▶ TIP — " + _FUN_FACTS.random()
	)
	add_child(tip_timer)


# Build the Loadout dropdown from best_loadouts.gd recipes. Idx 0 is
# always "默认 / DEFAULT" which clears Settings.loadout_ids; recipes
# follow. Pre-selects whatever the user picked last session (stored as
# Settings.loadout_ids — we match by id).
func _wire_loadout_picker() -> void:
	if loadout_picker == null:
		return
	loadout_picker.clear()
	loadout_picker.add_item("默认 / DEFAULT (AK20 · SG8 · SRX · RAILGUN)")
	loadout_picker.set_item_metadata(0, "")   # empty id = use DEFAULT_LOADOUT
	for i in _BEST_LOADOUTS.LOADOUTS.size():
		var rec: Dictionary = _BEST_LOADOUTS.LOADOUTS[i]
		loadout_picker.add_item(String(rec.get("name", rec.get("id", "?"))))
		loadout_picker.set_item_metadata(i + 1, String(rec.get("id", "")))
	loadout_picker.item_selected.connect(_on_loadout_changed)
	# Restore prior pick. We can't match by exact slot order against the
	# unordered list of recipes, but we DO save the recipe id below — pull
	# it from Settings.meta. Falls through to "default" on miss.
	var settings: Node = get_node_or_null(^"/root/Settings")
	if settings != null and "loadout_ids" in settings and not Array(settings.loadout_ids).is_empty():
		var saved_ids: Array = settings.loadout_ids
		# Find the recipe whose slots match saved_ids.
		for i in _BEST_LOADOUTS.LOADOUTS.size():
			var rec: Dictionary = _BEST_LOADOUTS.LOADOUTS[i]
			if Array(rec.get("slots", [])) == saved_ids:
				loadout_picker.select(i + 1)
				_on_loadout_changed(i + 1)
				return
	# No prior pick or no match — default.
	loadout_picker.select(0)
	_on_loadout_changed(0)


func _on_loadout_changed(idx: int) -> void:
	if loadout_picker == null:
		return
	var settings: Node = get_node_or_null(^"/root/Settings")
	if settings == null:
		return
	if idx == 0:
		settings.loadout_ids = []
		if loadout_desc != null:
			loadout_desc.text = "万金油默认配置 — 突击 · 散弹 · 狙击 · 重火。"
	else:
		var rec_idx: int = idx - 1
		if rec_idx < 0 or rec_idx >= _BEST_LOADOUTS.LOADOUTS.size():
			return
		var rec: Dictionary = _BEST_LOADOUTS.LOADOUTS[rec_idx]
		settings.loadout_ids = Array(rec.get("slots", []))
		if loadout_desc != null:
			loadout_desc.text = String(rec.get("desc", ""))
	if settings.has_method(&"save_to_disk"):
		settings.save_to_disk()


# ── Unlock code redemption ───────────────────────────────────────────────

func _on_open_redeem() -> void:
	redeem_input.text = ""
	redeem_status.text = ""
	redeem_dialog.popup_centered()
	redeem_input.grab_focus.call_deferred()


func _on_submit_redeem() -> void:
	var code: String = redeem_input.text.strip_edges()
	if code.is_empty():
		redeem_status.text = "兑换码不能为空"
		redeem_status.add_theme_color_override(&"font_color", Color(1, 0.5, 0.5))
		return
	# Redeem needs a network peer (server validates). If we're not yet
	# connected to the DS, prompt the user to CREATE / BROWSE first so the
	# DS handshake has fired.
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		redeem_status.text = "先点 CREATE ROOM 或 BROWSE 连上服务器,再来兑换"
		redeem_status.add_theme_color_override(&"font_color", Color(1, 0.7, 0.4))
		return
	var settings: Node = get_node_or_null(^"/root/Settings")
	if settings == null or not settings.has_method(&"request_redeem_code"):
		redeem_status.text = "internal error: Settings autoload missing"
		return
	settings.request_redeem_code(code)
	redeem_status.text = "提交中..."
	redeem_status.add_theme_color_override(&"font_color", Color(0.65, 0.85, 0.95))


func _on_settings_action(action: String, ok: bool, reason: String) -> void:
	# Server emits server_action for every acked mutation (purchase / upgrade
	# / chest / spin / redeem). Dispatch to whichever dialog is currently
	# open. Stale acks (dialog closed) are silently dropped.
	if action == "redeem_code" and redeem_dialog.visible:
		if ok:
			redeem_status.text = "✓ %s" % reason
			redeem_status.add_theme_color_override(&"font_color", Color(0.55, 0.95, 0.55))
			redeem_input.text = ""
		else:
			redeem_status.text = "✗ %s" % reason
			redeem_status.add_theme_color_override(&"font_color", Color(1, 0.55, 0.55))
	elif action == "spin" and wheel_dialog.visible:
		if ok:
			wheel_result.text = "✓ 转盘启动!等待奖品..."
			wheel_result.add_theme_color_override(&"font_color", Color(0.55, 0.95, 0.55))
			# The actual reward comes via reward_received signal (handled below)
		else:
			wheel_result.text = "✗ %s" % reason
			wheel_result.add_theme_color_override(&"font_color", Color(1, 0.55, 0.55))
			wheel_spin.disabled = false
	elif action == "upgrade" and weapons_dialog.visible:
		if ok:
			weapons_dialog.title = "武器图鉴 — ✓ 升级成功"
			# Refresh the upgrade levels by repopulating the dialog. Server's
			# profile push has already updated Settings.upgrades.
			_populate_weapons_dialog()
		else:
			weapons_dialog.title = "武器图鉴 — ✗ " + reason
	elif (action == "login" or action == "register") and login_dialog.visible:
		if ok:
			login_status.text = "✓ %s" % ("登录成功" if action == "login" else "账号已注册并绑定")
			login_status.add_theme_color_override(&"font_color", Color(0.55, 0.95, 0.55))
		else:
			login_status.text = "✗ %s" % reason
			login_status.add_theme_color_override(&"font_color", Color(1, 0.55, 0.55))


# ── Daily wheel ──────────────────────────────────────────────────────────

func _on_open_wheel() -> void:
	wheel_result.text = "点上面的按钮开始"
	wheel_result.add_theme_color_override(&"font_color", Color(0.95, 0.85, 0.45))
	wheel_spin.disabled = false
	wheel_dialog.popup_centered()


func _on_submit_spin() -> void:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		wheel_result.text = "先点 CREATE ROOM 或 BROWSE 连服务器,再来转盘"
		wheel_result.add_theme_color_override(&"font_color", Color(1, 0.7, 0.4))
		return
	var settings: Node = get_node_or_null(^"/root/Settings")
	if settings == null or not settings.has_method(&"request_spin_wheel"):
		return
	wheel_spin.disabled = true
	wheel_result.text = "转盘启动中..."
	wheel_result.add_theme_color_override(&"font_color", Color(0.65, 0.85, 0.95))
	settings.request_spin_wheel()


func _on_settings_reward(kind: String, reward: Dictionary) -> void:
	# server_reward fires whenever the server credits a reward (wheel /
	# chest / etc). For now only the wheel dialog cares.
	if kind != "wheel" or not wheel_dialog.visible:
		return
	var parts: Array[String] = []
	if reward.has("credits"):
		parts.append("信用点 +%d" % int(reward.credits))
	if reward.has("fragments"):
		parts.append("碎片 +%d" % int(reward.fragments))
	if reward.has("common_chests"):
		parts.append("普通宝箱 +%d" % int(reward.common_chests))
	if reward.has("rare_chests"):
		parts.append("稀有宝箱 +%d" % int(reward.rare_chests))
	var final_text: String = "✓ 转盘已完成" if parts.is_empty() else "★ 中奖: %s" % " / ".join(parts)
	_play_wheel_animation(final_text)
	wheel_spin.disabled = true   # consumed for 24h


# Wheel animation: cycle through 8 slot labels in the result label for ~1.8s
# (decelerating), then settle on the actual prize text. Pure cosmetic — the
# server already chose the reward + persisted it.
func _play_wheel_animation(final_text: String) -> void:
	var labels: Array[String] = [
		"50 信用点", "150 信用点", "300 信用点", "1000 信用点",
		"5 碎片", "15 碎片", "普通宝箱", "稀有宝箱",
	]
	var total_steps: int = 16
	var t: Tween = create_tween()
	for i in total_steps:
		# Step delay accelerates → decelerates so the wheel "feels" like
		# it's slowing down to a stop. Linear-ish at the end, fast early.
		var delay: float = 0.04 + (float(i) / float(total_steps)) * 0.18
		var label_idx: int = i % labels.size()
		var label: String = labels[label_idx]
		t.tween_callback(func():
			if is_instance_valid(wheel_result):
				wheel_result.text = "◯ %s" % label
				wheel_result.add_theme_color_override(&"font_color", Color(0.55, 0.85, 1, 1))
		).set_delay(delay)
	# Final settle.
	t.tween_callback(func():
		if is_instance_valid(wheel_result):
			wheel_result.text = final_text
			wheel_result.add_theme_color_override(&"font_color", Color(0.95, 0.85, 0.45))
	).set_delay(0.3)


# ── Account login / register ─────────────────────────────────────────────

func _on_open_login() -> void:
	login_handle.text = ""
	login_password.text = ""
	login_status.text = ""
	login_dialog.popup_centered()
	login_handle.grab_focus.call_deferred()


func _on_register_pressed() -> void:
	_submit_account("register")


func _on_login_pressed() -> void:
	_submit_account("login")


func _submit_account(action: String) -> void:
	var handle: String = login_handle.text.strip_edges()
	var password: String = login_password.text
	if handle.length() < 3 or handle.length() > 16:
		login_status.text = "账号名 3-16 字符"
		login_status.add_theme_color_override(&"font_color", Color(1, 0.55, 0.55))
		return
	if password.length() < 6:
		login_status.text = "密码至少 6 位"
		login_status.add_theme_color_override(&"font_color", Color(1, 0.55, 0.55))
		return
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		login_status.text = "先 CREATE ROOM / BROWSE 连服务器再来"
		login_status.add_theme_color_override(&"font_color", Color(1, 0.7, 0.4))
		return
	var settings: Node = get_node_or_null(^"/root/Settings")
	if settings == null:
		return
	if action == "register" and settings.has_method(&"request_register_account"):
		settings.request_register_account(handle, password)
	elif action == "login" and settings.has_method(&"request_login"):
		settings.request_login(handle, password)
	login_status.text = "提交中..."
	login_status.add_theme_color_override(&"font_color", Color(0.65, 0.85, 0.95))


# ── Custom Loadout editor ────────────────────────────────────────────────
# 4 separate OptionButtons, each filled with every weapon on disk. User
# picks a weapon per slot, Save writes Settings.loadout_ids; Reset goes
# back to DEFAULT_LOADOUT.

var _loadout_edit_weapon_ids: Array[String] = []   # ordered same as picker items


func _on_open_loadout_edit() -> void:
	_populate_loadout_edit_pickers()
	loadout_edit_status.text = ""
	loadout_edit_dialog.popup_centered()


func _populate_loadout_edit_pickers() -> void:
	# Scan disk once, build the same ID list for all 4 pickers.
	_loadout_edit_weapon_ids.clear()
	var pickers: Array[OptionButton] = [loadout_edit_slot1, loadout_edit_slot2, loadout_edit_slot3, loadout_edit_slot4]
	for p in pickers:
		p.clear()
	var dir := DirAccess.open("res://shared/data/weapons/")
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var fname: String = dir.get_next()
		if fname == "":
			break
		if fname.ends_with(".tres.remap"):
			fname = fname.substr(0, fname.length() - 6)
		if dir.current_is_dir() or fname.begins_with("_") or not fname.ends_with(".tres"):
			continue
		var wpn: Resource = load("res://shared/data/weapons/" + fname)
		if wpn == null:
			continue
		var wid: String = fname.replace(".tres", "")
		_loadout_edit_weapon_ids.append(wid)
		for p in pickers:
			p.add_item("%s (%s)" % [wpn.display_name, wpn.type_label])
	# Preselect each slot from Settings.loadout_ids (or DEFAULT_LOADOUT).
	var settings: Node = get_node_or_null(^"/root/Settings")
	var current: Array = []
	if settings != null and "loadout_ids" in settings and not Array(settings.loadout_ids).is_empty():
		current = settings.loadout_ids
	else:
		current = ["ak20", "sg8", "srx", "grenade"]
	for slot_i in 4:
		var target_id: String = String(current[slot_i]) if slot_i < current.size() else ""
		var idx: int = _loadout_edit_weapon_ids.find(target_id)
		if idx >= 0:
			pickers[slot_i].select(idx)
		else:
			pickers[slot_i].select(0)


func _on_loadout_edit_save() -> void:
	var pickers: Array[OptionButton] = [loadout_edit_slot1, loadout_edit_slot2, loadout_edit_slot3, loadout_edit_slot4]
	var ids: Array[String] = []
	for p in pickers:
		var idx: int = p.selected
		if idx < 0 or idx >= _loadout_edit_weapon_ids.size():
			continue
		ids.append(_loadout_edit_weapon_ids[idx])
	var settings: Node = get_node_or_null(^"/root/Settings")
	if settings == null:
		return
	settings.loadout_ids = Array(ids)
	if settings.has_method(&"save_to_disk"):
		settings.save_to_disk()
	loadout_edit_status.text = "✓ 已保存 4 槽自定义装备"
	loadout_edit_status.add_theme_color_override(&"font_color", Color(0.55, 0.95, 0.55))
	# Reset the LoadoutPicker selection to "default" since picking a recipe
	# would overwrite our custom save. Custom = no recipe match.
	if loadout_picker != null:
		loadout_picker.select(0)


func _on_loadout_edit_reset() -> void:
	# Re-populate with default ids selected.
	var defaults: Array = ["ak20", "sg8", "srx", "grenade"]
	var pickers: Array[OptionButton] = [loadout_edit_slot1, loadout_edit_slot2, loadout_edit_slot3, loadout_edit_slot4]
	for slot_i in 4:
		var idx: int = _loadout_edit_weapon_ids.find(String(defaults[slot_i]))
		if idx >= 0:
			pickers[slot_i].select(idx)
	loadout_edit_status.text = "已重置 (保存生效)"
	loadout_edit_status.add_theme_color_override(&"font_color", Color(0.85, 0.85, 0.55))
