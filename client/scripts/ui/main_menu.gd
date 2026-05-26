extends Control
class_name MainMenu

const GAME_SCENE := preload("res://client/scenes/game.tscn")
# Runtime-loaded (not preload) to avoid a circular dependency with shop.tscn,
# which preloads main_menu.tscn for its back button.
const SHOP_SCENE_PATH := "res://client/scenes/shop.tscn"

const MAPS := [
	{
		"name": "Blank — 空旷方形",
		"path": "res://shared/scenes/maps/blank.tscn",
		"desc": "60×60 米的开阔场地，两个矮障碍。适合熟悉操作、纯走位练习。无地形优势，纯枪法。",
	},
	{
		"name": "Battlefield — 平原工事",
		"path": "res://shared/scenes/maps/battlefield.tscn",
		"desc": "100×100 大地图，散落木箱、长墙、矮掩体。中远距离对枪 + 卡点对枪都好用。AR 和狙击都适合。",
	},
	{
		"name": "KOTH — 中央高地",
		"path": "res://shared/scenes/maps/koth.tscn",
		"desc": "80×80 场地，正中三层圆形小山是制高点。四个角落有小掩体。占山为王，视野压制。",
	},
	{
		"name": "Trenches — WW1 战壕",
		"path": "res://shared/scenes/maps/trenches.tscn",
		"desc": "南北双线战壕，中间无人区下沉。带战争雾化，限制远距离。突破或防守的攻防博弈。",
	},
	{
		"name": "Skydock — 立体平台",
		"path": "res://shared/scenes/maps/skydock.tscn",
		"desc": "三层垂直结构：底层 + 南北中层平台 + 顶层指挥台。斜坡互联。垂直作战、上下夹击。",
	},
]

const MODES_DIR := "res://shared/data/modes/"

# Built at _ready() by scanning MODES_DIR — same data-driven pattern as the
# weapon registry. Practice (no mode_def) is always first.
var MODES: Array = []

@onready var map_picker: OptionButton = $Scroll/Center/Cols/LeftCard/V/MapPicker
@onready var mode_picker: OptionButton = $Scroll/Center/Cols/LeftCard/V/ModePicker
@onready var map_desc: Label = $Scroll/Center/Cols/LeftCard/V/MapDescription
@onready var mode_desc: Label = $Scroll/Center/Cols/LeftCard/V/ModeDescription
@onready var weapons_btn: Button = $Scroll/Center/Cols/LeftCard/V/WeaponsButton
@onready var shop_btn: Button = $Scroll/Center/Cols/LeftCard/V/ShopButton
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
	stat_weapons.text = "▣  %d 武器" % weapon_count
	stat_modes.text = "◇  %d 模式" % MODES.size()
	stat_maps.text = "◈  %d 地图" % MAPS.size()
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
	status_label.text = "🔗 邀请链接：%s" % code
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
	skin_name_label.text = "Character %s   (%d / 18)" % [letter, s.skin_index + 1]
	_refresh_summary()


## Mirror the current left-side selections (map / mode / skin) into the
## right-card "you're about to play" pill, so picks visibly affect both
## halves of the screen instead of just updating a small description label.
func _refresh_summary() -> void:
	if summary_map != null and map_picker != null:
		var midx: int = clampi(map_picker.selected, 0, MAPS.size() - 1)
		summary_map.text = "📍  %s" % MAPS[midx].name
	if summary_mode != null and mode_picker != null and MODES.size() > 0:
		var oidx: int = clampi(mode_picker.selected, 0, MODES.size() - 1)
		summary_mode.text = "🎯  %s" % MODES[oidx].name
	if summary_skin != null and has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		var letter: String = "ABCDEFGHIJKLMNOPQR".substr(s.skin_index, 1)
		summary_skin.text = "👤  Character %s" % letter


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
	# Wipe any prior children (re-runs after first time should refresh content).
	for child in weapons_list.get_children():
		child.queue_free()
	# Scan all weapon .tres on disk; same source as in-game registry.
	var dir := DirAccess.open("res://shared/data/weapons/")
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var fname: String = dir.get_next()
		if fname == "":
			break
		if dir.current_is_dir() or fname.begins_with("_") or not fname.ends_with(".tres"):
			continue
		var wpn: Resource = load("res://shared/data/weapons/" + fname)
		if wpn == null:
			continue
		_append_weapon_row(wpn)
	dir.list_dir_end()


func _append_weapon_row(wpn: Resource) -> void:
	# ── Card container with cyan border + rounded corners ────────────────────
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(680, 0)
	card.add_theme_stylebox_override(&"panel", _weapon_card_style(wpn))

	var pad := MarginContainer.new()
	pad.add_theme_constant_override(&"margin_left", 18)
	pad.add_theme_constant_override(&"margin_right", 18)
	pad.add_theme_constant_override(&"margin_top", 14)
	pad.add_theme_constant_override(&"margin_bottom", 14)
	card.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 8)
	pad.add_child(col)

	# Header row: name + type + badges.
	var header := HBoxContainer.new()
	header.add_theme_constant_override(&"separation", 12)
	col.add_child(header)

	var name_lbl := Label.new()
	name_lbl.text = wpn.display_name
	name_lbl.add_theme_font_size_override(&"font_size", 22)
	name_lbl.add_theme_color_override(&"font_color", Color(1, 0.88, 0.42))
	header.add_child(name_lbl)

	var type_lbl := Label.new()
	type_lbl.text = "·  " + wpn.type_label
	type_lbl.add_theme_font_size_override(&"font_size", 14)
	type_lbl.add_theme_color_override(&"font_color", Color(0.55, 0.82, 1, 0.85))
	header.add_child(type_lbl)

	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(header_spacer)

	if wpn.instakill_headshot:
		header.add_child(_make_badge("☠ 头爆秒杀", Color(1, 0.4, 0.4)))
	if wpn.scary_close:
		header.add_child(_make_badge("⚠ 近战凶器", Color(1, 0.7, 0.3)))
	if wpn.free_starter:
		header.add_child(_make_badge("FREE", Color(0.5, 1, 0.6)))
	if wpn.admin_only:
		header.add_child(_make_badge("ADMIN", Color(1, 0.4, 0.7)))

	# Stat bars row (one per stat, 4 stats).
	var stats := GridContainer.new()
	stats.columns = 2
	stats.add_theme_constant_override(&"h_separation", 16)
	stats.add_theme_constant_override(&"v_separation", 4)
	col.add_child(stats)

	stats.add_child(_make_stat_bar("DMG",     int(wpn.damage),       0, 150, Color(1, 0.4, 0.35)))
	stats.add_child(_make_stat_bar("MAG",     wpn.magazine,           1, 60,  Color(0.5, 0.85, 1)))
	# Lower fire_interval is FASTER → invert for visual "fire rate" bar.
	var rof_inv: int = clampi(int(round(1500.0 - wpn.fire_interval_ms)), 0, 1500)
	stats.add_child(_make_stat_bar("ROF",     rof_inv,                0, 1500, Color(1, 0.85, 0.4)))
	var bspeed: int = 999 if wpn.is_hitscan() else int(wpn.bullet_speed)
	stats.add_child(_make_stat_bar("SPEED",   bspeed,                 60, 300, Color(0.6, 1, 0.7)))

	# Ability callout.
	if wpn.ability != null and not String(wpn.ability.name).is_empty():
		var ability_box := PanelContainer.new()
		var abox := StyleBoxFlat.new()
		abox.bg_color = Color(0.05, 0.1, 0.18, 0.7)
		abox.border_color = Color(0.5, 0.85, 1, 0.5)
		abox.border_width_left = 3
		abox.corner_radius_top_left = 4
		abox.corner_radius_top_right = 4
		abox.corner_radius_bottom_left = 4
		abox.corner_radius_bottom_right = 4
		abox.content_margin_left = 10
		abox.content_margin_right = 10
		abox.content_margin_top = 6
		abox.content_margin_bottom = 6
		ability_box.add_theme_stylebox_override(&"panel", abox)
		var avbox := VBoxContainer.new()
		avbox.add_theme_constant_override(&"separation", 2)
		ability_box.add_child(avbox)
		var ah := Label.new()
		ah.text = "⚡ %s" % wpn.ability.name
		ah.add_theme_color_override(&"font_color", Color(0.55, 0.95, 1))
		ah.add_theme_font_size_override(&"font_size", 13)
		avbox.add_child(ah)
		if not String(wpn.ability.description).is_empty():
			var ad := Label.new()
			ad.text = wpn.ability.description
			ad.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			ad.custom_minimum_size = Vector2(620, 0)
			ad.add_theme_font_size_override(&"font_size", 12)
			ad.add_theme_color_override(&"font_color", Color(0.85, 0.92, 1))
			avbox.add_child(ad)
		col.add_child(ability_box)

	# Description.
	if "description" in wpn and not wpn.description.is_empty():
		var desc := Label.new()
		desc.text = wpn.description
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.custom_minimum_size = Vector2(640, 0)
		desc.add_theme_font_size_override(&"font_size", 12)
		desc.add_theme_color_override(&"font_color", Color(0.78, 0.85, 0.95))
		col.add_child(desc)

	weapons_list.add_child(card)


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
	_launch_game()


func _on_host() -> void:
	var peer := WebSocketMultiplayerPeer.new()
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
		staging_status.text = "🌐  Hosting on :7777 — 等人加入"
		staging_count.text = "Connected: 1 (you) — 可以直接 START 单人开"
	else:
		staging_status.text = "🔗  Connecting to host..."
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
	staging_status.text = "🔗  Connected — 等房主点 START"
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
