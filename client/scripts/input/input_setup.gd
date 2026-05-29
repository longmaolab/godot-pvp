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


func _ensure_mouse(action_name: StringName, button: MouseButton) -> void:
	if InputMap.has_action(action_name):
		return
	InputMap.add_action(action_name)
	var ev := InputEventMouseButton.new()
	# Godot 4.6 typed button_index as MouseButton enum; passing a raw int triggers
	# the INT_AS_ENUM_WITHOUT_CAST warning. Casting via the explicit param type.
	ev.button_index = button
	InputMap.action_add_event(action_name, ev)
