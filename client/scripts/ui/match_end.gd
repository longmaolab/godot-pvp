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
		var label_name: String = "You (peer %d)" % p if is_self else "Peer %d" % p
		if p == winner_peer:
			label_name = "[W]" + label_name
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


func _on_return() -> void:
	get_tree().change_scene_to_file(MAIN_MENU_PATH)


func _on_play_again() -> void:
	# Reload the current scene fresh.
	get_tree().reload_current_scene()
