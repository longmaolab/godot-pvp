extends CanvasLayer
class_name CommsWheel
## Two-set chat wheel modeled on the original pvp-game (Z + X). Open it with
## Z (tactical lines) or X (social lines), pick a line by clicking or
## pressing the matching number key (1-9). Selection is broadcast over the
## net via NetRpc.client_chat_line and locally pushed to the HUD feed.

const TACTICAL := [
	{"text": "RUN!",                 "color": Color(1, 0.4, 0.4),   "emoji": "🏃"},
	{"text": "CHARGE!",              "color": Color(1, 0.4, 0.4),   "emoji": "⚔️"},
	{"text": "Cover me!",            "color": Color(1, 0.85, 0.3),  "emoji": "🛡️"},
	{"text": "Enemy spotted!",       "color": Color(1, 0.4, 0.4),   "emoji": "👁️"},
	{"text": "Push together!",       "color": Color(0.5, 0.95, 0.5),"emoji": "👊"},
	{"text": "Fall back!",           "color": Color(1, 0.5, 0.4),   "emoji": "⬅️"},
	{"text": "Sorry!",               "color": Color(0.55, 0.8, 1),  "emoji": "🙏"},
	{"text": "Nice shot!",           "color": Color(0.55, 0.85, 1), "emoji": "👍"},
	{"text": "Scatter!",             "color": Color(1, 0.65, 0.3),  "emoji": "💨"},
]

const SOCIAL := [
	{"text": "Let's break this deadlock!", "color": Color(1, 0.55, 0.8),  "emoji": "🤔"},
	{"text": "Hold position!",             "color": Color(1, 0.55, 0.3),  "emoji": "🛑"},
	{"text": "Regroup on me!",             "color": Color(0.55, 0.85, 1), "emoji": "🎯"},
	{"text": "Sniper!",                    "color": Color(1, 0.4, 0.4),   "emoji": "🔭"},
	{"text": "Watch your flank!",          "color": Color(1, 0.85, 0.3),  "emoji": "⚠️"},
	{"text": "Low HP!",                    "color": Color(1, 0.4, 0.4),   "emoji": "❤️"},
	{"text": "Thanks!",                    "color": Color(0.55, 0.95, 0.55),"emoji": "🙌"},
	{"text": "GG!",                        "color": Color(0.85, 0.55, 1), "emoji": "🏆"},
	{"text": "Distract them!",             "color": Color(1, 0.55, 0.8),  "emoji": "🎭"},
]

@onready var header: Label = $Center/Card/V/Header
@onready var lines_box: VBoxContainer = $Center/Card/V/Lines

var _current_set: String = ""
var _hud: Node = null


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS   # stay responsive even if paused
	# Try to find the HUD as a sibling so we can push selected lines into
	# the kill feed for self-confirmation.
	_hud = get_parent().get_node_or_null(^"HUD") if get_parent() else null
	if _hud == null:
		# Fallback: search the scene for any HUD.
		var nodes: Array = get_tree().get_nodes_in_group(&"hud")
		if not nodes.is_empty():
			_hud = nodes[0]


func _unhandled_input(event: InputEvent) -> void:
	# Toggle keys: Z = tactical wheel, X = social wheel.
	if event is InputEventKey and event.pressed and not event.echo:
		if visible and event.keycode == KEY_ESCAPE:
			close()
			return
		if event.keycode == KEY_Z:
			open(&"tactical")
			return
		if event.keycode == KEY_X:
			open(&"social")
			return
		if visible and event.keycode >= KEY_1 and event.keycode <= KEY_9:
			var idx: int = event.keycode - KEY_1
			_select(idx)
			return


func open(which: StringName) -> void:
	# Re-pressing the same wheel toggles it; pressing the other wheel switches.
	if visible and _current_set == which:
		close()
		return
	_current_set = which
	_render_lines()
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _render_lines() -> void:
	for child in lines_box.get_children():
		child.queue_free()
	var set_data: Array = TACTICAL if _current_set == &"tactical" else SOCIAL
	header.text = "TACTICAL  /  Z" if _current_set == &"tactical" else "SOCIAL  /  X"
	for i in set_data.size():
		var line: Dictionary = set_data[i]
		var btn := Button.new()
		btn.text = "%d.  %s  %s" % [i + 1, line["emoji"], line["text"]]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_color_override(&"font_color", line["color"])
		btn.add_theme_font_size_override(&"font_size", 14)
		btn.custom_minimum_size = Vector2(340, 30)
		var captured_index: int = i
		btn.pressed.connect(func(): _select(captured_index))
		lines_box.add_child(btn)


func _select(idx: int) -> void:
	var set_data: Array = TACTICAL if _current_set == &"tactical" else SOCIAL
	if idx < 0 or idx >= set_data.size():
		return
	var line: Dictionary = set_data[idx]
	# Local: push to HUD feed.
	if _hud != null and _hud.has_method(&"push_feed"):
		_hud.push_feed("📣  " + String(line["text"]), line["color"])
	# Network: broadcast via NetRpc autoload (only meaningful in MP).
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null and multiplayer.has_multiplayer_peer() \
			and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		net_rpc.client_chat_line.rpc_id(1, String(line["text"]), line["color"])
	close()
