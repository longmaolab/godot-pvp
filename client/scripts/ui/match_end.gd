extends CanvasLayer
class_name MatchEnd
## Endgame overlay. Shown when MatchController emits match_ended (listen-host
## practice) OR when DS broadcasts server_match_ended to the room (MP path).
##
## Renders winner banner + per-peer scoreboard, surfaces the room state so a
## joiner knows whether the room still exists and what their role is, and
## handles Play Again by either reloading the scene (listen-host) or sending
## client_start_match with explicit reject feedback (DS path).

const MAIN_MENU_PATH := "res://client/scenes/main_menu.tscn"
const UiStyle = preload("res://client/scripts/ui/ui_style.gd")

@onready var title: Label = $Center/Card/V/Title
@onready var scoreboard_list: VBoxContainer = $Center/Card/V/ScoreboardList
@onready var return_btn: Button = $Center/Card/V/ButtonsRow/ReturnButton
@onready var play_again_btn: Button = $Center/Card/V/ButtonsRow/PlayAgainButton
@onready var card_v: VBoxContainer = $Center/Card/V
@onready var subtitle: Label = $Center/Card/V/Subtitle

var local_peer: int = 1   # set from game_controller before show_for()
var current_scene_path: String = "res://client/scenes/game.tscn"
# Where Return / Play Again actually go. Default = main menu (legacy
# listen-host path). DS-client overrides via set_return_target() to
# bounce back to the room lobby so the player can re-ready for round 2.
var _return_scene_path: String = MAIN_MENU_PATH
var _play_again_scene_path: String = ""   # "" = reload current scene
# Per-peer profile dict from server (Room.to_dict.profiles): peer_id →
# {name, skin, ready}. Used to render real names instead of "Peer N".
var _profiles: Dictionary = {}
# Optional override for the Play Again button. When set, click invokes
# this Callable instead of doing a scene change. DS-client uses it to
# send client_start_match RPC so a click goes straight into the next
# round instead of bouncing through the lobby.
var _play_again_callable: Callable = Callable()
# Room state from server (id, host, players, profiles, last_winner,
# last_scores). When empty the room is gone and Play Again is hidden.
var _room_state: Dictionary = {}
# Lazily built status labels — surfaced under Subtitle and above the
# button row so room state and reject reasons are visible to the user.
var _room_status_label: Label = null
var _action_status_label: Label = null

# Map server-side reject reasons (from server_start_match_failed RPC) to
# Chinese-first user-facing copy. Unknown reasons fall back to the raw tag
# so a future server-side reason still surfaces something to the user
# instead of silent failure.
const REJECT_REASONS: Dictionary = {
	"no_room": "你已经不在任何房间里。点「返回菜单」回主菜单。",
	"room_gone": "房间已解散。点「返回菜单」回主菜单。",
	"not_host": "只有房主能开新一局。等房主决定。",
	"already_running": "新一局已经在开了，稍等。",
}


func _ready() -> void:
	return_btn.pressed.connect(_on_return)
	play_again_btn.pressed.connect(_on_play_again)
	UiStyle.style_button(play_again_btn, "primary")
	UiStyle.style_button(return_btn, "neutral")
	_build_status_labels()
	# Subscribe to the server's rejection feedback. _on_start_match_failed
	# re-enables the button + shows a reason instead of leaving the user
	# staring at a frozen disabled button.
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		if "server_start_match_failed_received" in net_rpc:
			if not net_rpc.server_start_match_failed_received.is_connected(_on_start_match_failed):
				net_rpc.server_start_match_failed_received.connect(_on_start_match_failed)
		# When server accepts our (or another room member's) start_match,
		# it broadcasts server_match_starting. We're an overlay on the
		# already-loaded game.tscn — reload that scene so the fresh
		# _enter_client_mode pulls a clean spawn snapshot for round 2.
		if "server_match_starting_received" in net_rpc:
			if not net_rpc.server_match_starting_received.is_connected(_on_match_starting):
				net_rpc.server_match_starting_received.connect(_on_match_starting)


## Populate the screen and present. winner_peer == local_peer → VICTORY (green
## title), else DEFEAT (red). scores expected: { kills, deaths, round_wins }.
func show_for(winner_peer: int, scores: Dictionary, local_peer_id: int) -> void:
	local_peer = local_peer_id
	if winner_peer == local_peer:
		title.text = "VICTORY"
		title.add_theme_color_override(&"font_outline_color", Color(0.1, 0.5, 0.2, 1))
	elif winner_peer > 0:
		title.text = "DEFEAT"
		title.add_theme_color_override(&"font_outline_color", Color(0.55, 0.1, 0.1, 1))
	else:
		title.text = "MATCH OVER"
		title.add_theme_color_override(&"font_outline_color", Color(0.45, 0.3, 0.55, 1))

	_render_scoreboard(scores, winner_peer)
	_refresh_room_status()


func _render_scoreboard(scores: Dictionary, winner_peer: int) -> void:
	for child in scoreboard_list.get_children():
		child.queue_free()

	var kills: Dictionary = scores.get("kills", {})
	var deaths: Dictionary = scores.get("deaths", {})
	var round_wins: Dictionary = scores.get("round_wins", {})

	# Build a sorted list of every peer that appears in any tracking dict.
	var peers: Dictionary = {}
	for p in kills.keys():
		peers[p] = true
	for p in deaths.keys():
		peers[p] = true
	for p in round_wins.keys():
		peers[p] = true
	var peer_list: Array = peers.keys()
	peer_list.sort_custom(func(a, b):
		return int(kills.get(a, 0)) > int(kills.get(b, 0)))

	if peer_list.is_empty():
		var empty := Label.new()
		empty.text = "(no kill data recorded)"
		empty.add_theme_color_override(&"font_color", Color(0.6, 0.7, 0.85))
		empty.add_theme_font_size_override(&"font_size", 13)
		scoreboard_list.add_child(empty)
		return

	# Header row.
	var header := _make_row(
		"PLAYER", "K", "D", "RW",
		Color(0.55, 0.78, 0.95, 0.6), true, false)
	scoreboard_list.add_child(header)

	for p in peer_list:
		var is_self: bool = (p == local_peer)
		var resolved: String = _peer_display_name(p)
		var label_name: String = ("%s (你)" % resolved) if is_self else resolved
		if p == winner_peer:
			label_name = "[W] " + label_name
		var row := _make_row(
			label_name,
			str(int(kills.get(p, 0))),
			str(int(deaths.get(p, 0))),
			str(int(round_wins.get(p, 0))),
			Color(1, 1, 1, 1), false, is_self)
		scoreboard_list.add_child(row)


func _make_row(name_txt: String, k: String, d: String, rw: String,
		color: Color, is_header: bool, is_self: bool) -> PanelContainer:
	var pc := PanelContainer.new()
	# Use the pre-baked StyleBoxFlat resources defined in the .tscn for highlight.
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.15, 0.35, 0.55, 0.6) if is_self else Color(0.06, 0.12, 0.2, 0.5)
	s.border_color = Color(0.4, 0.85, 1, 0.85) if is_self else Color(0.3, 0.55, 0.8, 0.5)
	s.border_width_left = 3 if is_self else 2
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6
	s.corner_radius_bottom_right = 6
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	pc.add_theme_stylebox_override(&"panel", s)

	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 12)
	pc.add_child(row)

	var n := Label.new()
	n.text = name_txt
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.add_theme_font_size_override(&"font_size", 14 if not is_header else 12)
	n.add_theme_color_override(&"font_color", color if not is_self else Color(1, 1, 1))
	row.add_child(n)

	for stat_txt in [k, d, rw]:
		var l := Label.new()
		l.text = stat_txt
		l.custom_minimum_size = Vector2(48, 0)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override(&"font_size", 14 if not is_header else 12)
		l.add_theme_color_override(&"font_color", color if not is_self else Color(1, 1, 1))
		row.add_child(l)

	return pc


## DS-client calls this to redirect Return to whichever scene makes sense
## (lobby if room survives, main menu otherwise). Play Again can either
## scene-change or invoke a Callable (e.g. send client_start_match RPC).
func set_return_target(return_path: String, play_again_label: String = "Play Again",
		play_again_path: String = "") -> void:
	_return_scene_path = return_path
	_play_again_scene_path = play_again_path
	if play_again_btn != null:
		play_again_btn.text = play_again_label


## Override Play Again click to run a Callable instead of a scene change.
## DS-client sets this to "send client_start_match RPC" so the user goes
## straight into the next round without bouncing through the lobby.
func set_play_again_callable(cb: Callable, label: String = "再来一局 / PLAY AGAIN") -> void:
	_play_again_callable = cb
	if play_again_btn != null:
		play_again_btn.text = label


## Pass the server's per-peer profile dict so the scoreboard can render
## real names instead of "Peer 1304920972". Profiles dict shape:
##   { peer_id (int or str) → {name, skin, ready} }
func set_profiles(profiles: Dictionary) -> void:
	_profiles = profiles


## Pass the room state dictionary (Room.to_dict shape). Drives:
##   - room id + player count + your role under the title
##   - Play Again visibility (room destroyed → hidden)
## Empty dict = room gone; only Return button remains usable.
func set_room_state(room_state: Dictionary) -> void:
	_room_state = room_state
	_refresh_room_status()


func _peer_display_name(peer_id: int) -> String:
	# Profile dict may have int or string keys depending on RPC coercion.
	var prof: Dictionary = _profiles.get(peer_id, _profiles.get(str(peer_id), {}))
	var name_text: String = String(prof.get("name", ""))
	return name_text if not name_text.is_empty() else "Player %d" % peer_id


# ── Status labels ────────────────────────────────────────────────────────

func _build_status_labels() -> void:
	# Room status sits right under Subtitle. Action status sits right
	# above the button row. Both are inserted via move_child so the
	# VBox preserves an intuitive order even though they're built late.
	_room_status_label = Label.new()
	_room_status_label.name = "RoomStatus"
	_room_status_label.add_theme_font_size_override(&"font_size", 14)
	_room_status_label.add_theme_color_override(&"font_color", Color(0.65, 0.85, 1, 0.95))
	_room_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card_v.add_child(_room_status_label)
	card_v.move_child(_room_status_label, subtitle.get_index() + 1)

	_action_status_label = Label.new()
	_action_status_label.name = "ActionStatus"
	_action_status_label.add_theme_font_size_override(&"font_size", 13)
	_action_status_label.add_theme_color_override(&"font_color", Color(1, 0.7, 0.55, 0.9))
	_action_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_action_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_action_status_label.text = ""
	card_v.add_child(_action_status_label)
	card_v.move_child(_action_status_label, play_again_btn.get_parent().get_index())


func _refresh_room_status() -> void:
	if _room_status_label == null:
		return
	if _room_state.is_empty():
		_room_status_label.text = "房间已不存在"
		_room_status_label.add_theme_color_override(&"font_color", Color(1, 0.55, 0.55, 0.95))
		# Without a room, Play Again has nowhere to go. Hide it.
		if play_again_btn != null:
			play_again_btn.visible = false
		return
	var room_id: String = String(_room_state.get("id", "?"))
	var players: Array = _room_state.get("players", [])
	var host_peer: int = int(_room_state.get("host", 0))
	var is_host: bool = (local_peer == host_peer)
	var role_text: String = "[HOST] 房主" if is_host else "[JOINER] 加入者"
	_room_status_label.text = "房间 %s · %d 人 · %s" % [room_id, players.size(), role_text]
	_room_status_label.add_theme_color_override(&"font_color", Color(0.65, 0.85, 1, 0.95))
	if play_again_btn != null:
		play_again_btn.visible = true
		# Joiner sees a different verb — they're requesting, not commanding.
		# (Don't overwrite a label explicitly set by set_play_again_callable
		# unless the caller hasn't customized it yet.)
		if play_again_btn.text == "再来一局 / PLAY AGAIN" and not is_host:
			play_again_btn.text = "请求再来一局 / REQUEST REMATCH"


# ── Button handlers ──────────────────────────────────────────────────────

func _on_return() -> void:
	get_tree().change_scene_to_file(_return_scene_path)


func _on_play_again() -> void:
	# Disable + show pending so the user gets visible feedback while the
	# RPC round-trips. On reject we re-enable; on success the scene swaps.
	play_again_btn.disabled = true
	if _action_status_label != null:
		_action_status_label.text = "请求中..."
		_action_status_label.add_theme_color_override(&"font_color", Color(0.75, 0.9, 1, 0.9))
	if _play_again_callable.is_valid():
		_play_again_callable.call()
		return
	if _play_again_scene_path.is_empty():
		# Legacy listen-host: reload the current game scene fresh.
		get_tree().reload_current_scene()
	else:
		get_tree().change_scene_to_file(_play_again_scene_path)


## Server accepted (someone's) client_start_match — broadcast came back.
## Reload the game scene so we get a clean _enter_client_mode pass for the
## new round (fresh local PlayerController, fresh _input_tick=0, fresh HUD).
func _on_match_starting() -> void:
	get_tree().change_scene_to_file(current_scene_path)


func _on_start_match_failed(reason: String) -> void:
	# Re-enable the button so the user can try again (e.g. wait for host).
	if play_again_btn != null:
		play_again_btn.disabled = false
	if _action_status_label != null:
		_action_status_label.text = REJECT_REASONS.get(reason, "无法开始新一局：%s" % reason)
		_action_status_label.add_theme_color_override(&"font_color", Color(1, 0.65, 0.45, 1))
	# A reason of "no_room" or "room_gone" means the room is dead. Hide
	# Play Again entirely so the user doesn't bash a permanently-failing
	# button. They can still hit Return.
	if reason == "no_room" or reason == "room_gone":
		if play_again_btn != null:
			play_again_btn.visible = false
		_room_state = {}
		_refresh_room_status()
