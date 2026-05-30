extends Node
## Autoload — installs the InputMap programmatically so we don't depend on
## a hand-edited project.godot input section. Keys mirror the original
## /Users/longmao/projects/pvp-game/public/game.js controls.

const ACTIONS := {
	&"move_forward":  [KEY_W],
	&"move_back":     [KEY_S],
	&"move_left":     [KEY_A],
	&"move_right":    [KEY_D],
	&"jump":          [KEY_SPACE],
	&"sprint":        [KEY_SHIFT],
	&"crouch":        [KEY_CTRL],
	&"reload":        [KEY_R],
	&"ads":           [KEY_E],
	&"ability":       [KEY_Q],
	&"melee":         [KEY_F],
	# Lean / peek. Q/E (the genre default) are taken by ability/ADS here, so
	# lean uses C/V (free, left-hand) with the arrow keys as intuitive alts.
	&"lean_left":     [KEY_C, KEY_LEFT],
	&"lean_right":    [KEY_V, KEY_RIGHT],
	&"comms_primary": [KEY_Z],
	&"comms_secondary": [KEY_X],
	&"scoreboard":    [KEY_TAB],
	&"slot_1":        [KEY_1],
	&"slot_2":        [KEY_2],
	&"slot_3":        [KEY_3],
	&"slot_4":        [KEY_4],
}


func _ready() -> void:
	for action_name in ACTIONS:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
			for keycode in ACTIONS[action_name]:
				var ev := InputEventKey.new()
				ev.physical_keycode = keycode
				InputMap.action_add_event(action_name, ev)

	# Mouse buttons can't sit in the keycode table cleanly.
	_ensure_mouse(&"fire", MOUSE_BUTTON_LEFT)
	_ensure_mouse(&"alt_fire", MOUSE_BUTTON_RIGHT)

	# Replace the OS arrow (shown in menus / pause) with a themed cyan
	# crosshair-pointer, procedurally drawn so it needs no image asset.
	# Hotspot at the center so clicking menu buttons stays accurate.
	_install_custom_cursor()


## Draw a 28×28 cyan crosshair-with-dot cursor and install it. Center hotspot.
func _install_custom_cursor() -> void:
	var s := 28
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := s / 2
	var cyan := Color(0.45, 0.85, 1.0, 1.0)
	var dark := Color(0.02, 0.06, 0.12, 0.9)
	# 4 arms (gap in the middle) + center dot. Draw a 1px dark outline so it
	# reads on both light and dark backgrounds.
	for i in range(s):
		var d := absi(i - c)
		if d >= 3 and d <= 12:
			# vertical arm
			_px(img, c, i, cyan); _px(img, c - 1, i, dark); _px(img, c + 1, i, dark)
			# horizontal arm
			_px(img, i, c, cyan); _px(img, i, c - 1, dark); _px(img, i, c + 1, dark)
	# center dot
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			_px(img, c + dx, c + dy, cyan)
	var tex := ImageTexture.create_from_image(img)
	Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, Vector2(c, c))


func _px(img: Image, x: int, y: int, col: Color) -> void:
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return
	# Don't overwrite the bright cyan with the dark outline.
	if col.a < 1.0 and img.get_pixel(x, y).a > 0.5:
		return
	img.set_pixel(x, y, col)


func _ensure_mouse(action_name: StringName, button: MouseButton) -> void:
	if InputMap.has_action(action_name):
		return
	InputMap.add_action(action_name)
	var ev := InputEventMouseButton.new()
	# Godot 4.6 typed button_index as MouseButton enum; passing a raw int triggers
	# the INT_AS_ENUM_WITHOUT_CAST warning. Casting via the explicit param type.
	ev.button_index = button
	InputMap.action_add_event(action_name, ev)
