extends CanvasLayer
class_name MatchEnd
## Endgame overlay. Shown when MatchController emits match_ended.

const MAIN_MENU_PATH := "res://client/scenes/main_menu.tscn"

@onready var title: Label = $Center/Card/V/Title
@onready var scoreboard_list: VBoxContainer = $Center/Card/V/ScoreboardList
@onready var return_btn: Button = $Center/Card/V/ButtonsRow/ReturnButton
@onready var play_again_btn: Button = $Center/Card/V/ButtonsRow/PlayAgainButton

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


func _ready() -> void:
	return_btn.pressed.connect(_on_return)
	play_again_btn.pressed.connect(_on_play_again)


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


func _peer_display_name(peer_id: int) -> String:
	# Profile dict may have int or string keys depending on RPC coercion.
	var prof: Dictionary = _profiles.get(peer_id, _profiles.get(str(peer_id), {}))
	var name_text: String = String(prof.get("name", ""))
	return name_text if not name_text.is_empty() else "Player %d" % peer_id


func _on_return() -> void:
	get_tree().change_scene_to_file(_return_scene_path)


func _on_play_again() -> void:
	if _play_again_callable.is_valid():
		_play_again_callable.call()
		return
	if _play_again_scene_path.is_empty():
		# Legacy listen-host: reload the current game scene fresh.
		get_tree().reload_current_scene()
	else:
		get_tree().change_scene_to_file(_play_again_scene_path)
