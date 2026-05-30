extends Control
## Mobile / touch overlay — ported from arena-shooter-3d/scripts/touch_controls.gd
## and adapted to godot-pvp's action set + player API.
##
## Layout: left ~36% of screen = virtual joystick (appears under the finger,
## push to the rim to sprint), right side = drag-to-look (tap = fire),
## bottom-right cluster = RELOAD / FIRE / JUMP + ADS, with weapon-slot chips
## above. Minimal scheme — slide / lean / crouch / melee / ability are desktop-
## only for now. Auto-shows on touch devices, hidden on desktop.

const ACTIONS := {
	"left":    "move_left",
	"right":   "move_right",
	"forward": "move_forward",
	"back":    "move_back",
	"jump":    "jump",
	"fire":    "fire",
	"reload":  "reload",
	"ads":     "ads",
	"sprint":  "sprint",
}

# ─── Feel knobs ─────────────────────────────────────────────────────
const LOOK_SENSITIVITY := 0.0030    # rad / px
const LOOK_DEAD_PX     := 1.2
const JOY_DEADZONE     := 0.12
const SPRINT_THRESHOLD := 0.92      # joystick magnitude past which we also sprint
const TAP_FIRE_MAX_DRAG := 18.0
const TAP_FIRE_MAX_TIME := 0.28
const TAP_FIRE_PULSE    := 0.09

# ─── Sizing ─────────────────────────────────────────────────────────
const JOY_RADIUS_MIN   := 110.0
const JOY_RADIUS_RATIO := 0.17
const BTN_SIZE_MIN     := 110.0
const BTN_SIZE_RATIO   := 0.15
const BTN_MARGIN       := 26.0
const BTN_GAP          := 20.0
const MOVE_ZONE_X      := 0.36

var _joy_radius := JOY_RADIUS_MIN
var _btn_size   := BTN_SIZE_MIN

var _move_touch_id := -1
var _move_origin   := Vector2.ZERO
var _move_knob     := Vector2.ZERO
var _move_active   := false

var _look_touch_id := -1
var _look_last     := Vector2.ZERO
var _look_start    := Vector2.ZERO
var _look_t0       := 0.0
var _look_dragged  := false

var _fire_touch_id   := -1
var _jump_touch_id   := -1
var _reload_touch_id := -1
var _ads_touch_id    := -1

var _fire_rect   := Rect2()
var _jump_rect   := Rect2()
var _reload_rect := Rect2()
var _ads_rect    := Rect2()

const WEAPON_LABELS := ["1", "2", "3", "4"]
const WEAPON_COLORS := [Color(0.85, 0.85, 0.95), Color(0.55, 0.85, 1.0), Color(1.0, 0.65, 0.45), Color(0.7, 1.0, 0.6)]
var _weapon_rects := [Rect2(), Rect2(), Rect2(), Rect2()]
var _weapon_touch_ids := [-1, -1, -1, -1]
var _active_weapon: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = _is_touch_device()
	if not visible:
		set_process_input(false)
		return
	get_viewport().size_changed.connect(_recalc_layout)
	_recalc_layout()


func _is_touch_device() -> bool:
	if DisplayServer.is_touchscreen_available():
		return true
	if OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios"):
		return true
	return false


func _recalc_layout() -> void:
	var s := get_viewport().get_visible_rect().size
	_joy_radius = max(JOY_RADIUS_MIN, s.y * JOY_RADIUS_RATIO)
	_btn_size   = max(BTN_SIZE_MIN, s.y * BTN_SIZE_RATIO)
	var right_x: float  = s.x - BTN_MARGIN - _btn_size
	var bottom_y: float = s.y - BTN_MARGIN - _btn_size
	# Right-thumb cluster:
	#            [JUMP]
	#   [RELOAD] [FIRE]
	#       [ADS]
	_fire_rect   = Rect2(right_x, bottom_y, _btn_size, _btn_size)
	_reload_rect = Rect2(right_x - _btn_size - BTN_GAP, bottom_y, _btn_size, _btn_size)
	_jump_rect   = Rect2(right_x, bottom_y - _btn_size - BTN_GAP, _btn_size, _btn_size)
	# ADS sits left of FIRE, one row down feel — put it under RELOAD.
	_ads_rect    = Rect2(right_x - _btn_size - BTN_GAP, bottom_y - _btn_size - BTN_GAP, _btn_size, _btn_size)
	# Weapon chips: VERTICAL column on the LEFT edge (out of the center
	# sightline). Stacked bottom-up so 1 is lowest (near the move thumb),
	# 4 highest. Was a horizontal row across mid-screen blocking the view.
	var w_size: float = _btn_size * 0.5
	var w_gap: float = 10.0
	var w_x: float = BTN_MARGIN
	# Anchor the column's bottom a bit above vertical center so it clears the
	# move joystick zone below and stays off the horizon line.
	var col_bottom: float = s.y * 0.52
	for i in WEAPON_LABELS.size():
		var y: float = col_bottom - i * (w_size + w_gap)
		_weapon_rects[i] = Rect2(w_x, y, w_size, w_size)
	queue_redraw()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		var w_idx := _weapon_index_at(event.position)
		if w_idx >= 0:
			_weapon_touch_ids[w_idx] = event.index
			_request_weapon_switch(w_idx)
			queue_redraw()
			return
		if _fire_rect.has_point(event.position):
			_fire_touch_id = event.index
			Input.action_press(ACTIONS["fire"])
			queue_redraw()
		elif _jump_rect.has_point(event.position):
			_jump_touch_id = event.index
			Input.action_press(ACTIONS["jump"])
			queue_redraw()
		elif _reload_rect.has_point(event.position):
			_reload_touch_id = event.index
			Input.action_press(ACTIONS["reload"])
			queue_redraw()
		elif _ads_rect.has_point(event.position):
			_ads_touch_id = event.index
			Input.action_press(ACTIONS["ads"])
			queue_redraw()
		elif event.position.x < get_viewport().get_visible_rect().size.x * MOVE_ZONE_X:
			_move_touch_id = event.index
			_move_origin = _clamp_joystick_origin(event.position)
			_move_knob = event.position
			_move_active = true
			queue_redraw()
		else:
			_look_touch_id = event.index
			_look_last = event.position
			_look_start = event.position
			_look_t0 = Time.get_ticks_msec() * 0.001
			_look_dragged = false
	else:
		if event.index == _fire_touch_id:
			_fire_touch_id = -1
			Input.action_release(ACTIONS["fire"])
			queue_redraw()
		elif event.index == _jump_touch_id:
			_jump_touch_id = -1
			Input.action_release(ACTIONS["jump"])
			queue_redraw()
		elif event.index == _reload_touch_id:
			_reload_touch_id = -1
			Input.action_release(ACTIONS["reload"])
			queue_redraw()
		elif event.index == _ads_touch_id:
			_ads_touch_id = -1
			Input.action_release(ACTIONS["ads"])
			queue_redraw()
		elif event.index == _move_touch_id:
			_move_touch_id = -1
			_move_active = false
			_set_move_vector(Vector2.ZERO)
			Input.action_release(ACTIONS["sprint"])
			queue_redraw()
		elif event.index == _look_touch_id:
			var dt: float = Time.get_ticks_msec() * 0.001 - _look_t0
			var moved: float = (event.position - _look_start).length()
			if not _look_dragged and dt < TAP_FIRE_MAX_TIME and moved < TAP_FIRE_MAX_DRAG:
				_pulse_fire()
			_look_touch_id = -1
		else:
			for i in _weapon_touch_ids.size():
				if event.index == _weapon_touch_ids[i]:
					_weapon_touch_ids[i] = -1
					queue_redraw()
					break


func _weapon_index_at(pos: Vector2) -> int:
	for i in _weapon_rects.size():
		if _weapon_rects[i].has_point(pos):
			return i
	return -1


func _request_weapon_switch(idx: int) -> void:
	var p := get_tree().get_first_node_in_group("local_player")
	if p == null or not p.has_method("equip_slot"):
		return
	p.equip_slot(idx)
	_active_weapon = idx
	if "weapon_switched" in p and not p.weapon_switched.is_connected(_on_player_weapon_changed):
		p.weapon_switched.connect(_on_player_weapon_changed)


func _on_player_weapon_changed(new_weapon: Resource) -> void:
	# Map the equipped resource back to its loadout slot for the highlight.
	var p := get_tree().get_first_node_in_group("local_player")
	if p != null and "loadout" in p:
		var idx: int = (p.loadout as Array).find(new_weapon)
		if idx >= 0:
			_active_weapon = idx
			queue_redraw()


func _clamp_joystick_origin(p: Vector2) -> Vector2:
	var s := get_viewport().get_visible_rect().size
	return Vector2(
		clamp(p.x, _joy_radius, s.x - _joy_radius),
		clamp(p.y, _joy_radius, s.y - _joy_radius))


func _handle_drag(event: InputEventScreenDrag) -> void:
	if event.index == _move_touch_id:
		var offset := event.position - _move_origin
		if offset.length() > _joy_radius:
			offset = offset.normalized() * _joy_radius
		_move_knob = _move_origin + offset
		var raw := offset / _joy_radius
		var mag := raw.length()
		if mag < JOY_DEADZONE:
			_set_move_vector(Vector2.ZERO)
		else:
			var t := (mag - JOY_DEADZONE) / (1.0 - JOY_DEADZONE)
			_set_move_vector(raw.normalized() * t)
		# Push to the rim to sprint.
		if mag >= SPRINT_THRESHOLD:
			Input.action_press(ACTIONS["sprint"])
		else:
			Input.action_release(ACTIONS["sprint"])
		queue_redraw()
	elif event.index == _look_touch_id:
		var delta := event.position - _look_last
		if delta.length() < LOOK_DEAD_PX:
			return
		_look_last = event.position
		if not _look_dragged and (event.position - _look_start).length() > TAP_FIRE_MAX_DRAG:
			_look_dragged = true
		var p := get_tree().get_first_node_in_group("local_player")
		if p and p.has_method("apply_touch_look"):
			p.apply_touch_look(delta * LOOK_SENSITIVITY)


func _pulse_fire() -> void:
	Input.action_press(ACTIONS["fire"])
	await get_tree().create_timer(TAP_FIRE_PULSE).timeout
	Input.action_release(ACTIONS["fire"])


func _set_move_vector(v: Vector2) -> void:
	_set_action(ACTIONS["right"],   max(0.0, v.x))
	_set_action(ACTIONS["left"],    max(0.0, -v.x))
	_set_action(ACTIONS["back"],    max(0.0, v.y))
	_set_action(ACTIONS["forward"], max(0.0, -v.y))


func _set_action(action: String, strength: float) -> void:
	if strength > 0.0:
		Input.action_press(action, min(1.0, strength))
	else:
		Input.action_release(action)


# ─── Drawing ────────────────────────────────────────────────────────
func _draw() -> void:
	if not visible:
		return
	if _move_active:
		_draw_joystick()
	_draw_button(_fire_rect, "FIRE", Color(1, 0.35, 0.35), _fire_touch_id != -1)
	_draw_button(_jump_rect, "JUMP", Color(0.4, 0.7, 1), _jump_touch_id != -1)
	_draw_button(_reload_rect, "RELOAD", Color(1, 0.85, 0.4), _reload_touch_id != -1)
	_draw_button(_ads_rect, "ADS", Color(0.7, 0.9, 0.8), _ads_touch_id != -1)
	for i in WEAPON_LABELS.size():
		_draw_button(_weapon_rects[i], WEAPON_LABELS[i], WEAPON_COLORS[i], i == _active_weapon)


func _draw_joystick() -> void:
	draw_circle(_move_origin, _joy_radius, Color(1, 1, 1, 0.10))
	draw_arc(_move_origin, _joy_radius, 0, TAU, 64, Color(1, 1, 1, 0.45), 4.0, true)
	var knob_r := _joy_radius * 0.32
	draw_circle(_move_knob, knob_r, Color(1, 1, 1, 0.65))
	draw_arc(_move_knob, knob_r, 0, TAU, 32, Color(1, 1, 1, 0.85), 2.0, true)


func _draw_button(rect: Rect2, label: String, base_color: Color, pressed: bool) -> void:
	var center := rect.position + rect.size / 2
	var radius: float = rect.size.x / 2.0
	if pressed:
		var halo := base_color
		halo.a = 0.20
		draw_circle(center, radius * 1.12, halo)
	var fill := base_color
	fill.a = 0.85 if pressed else 0.42
	var r: float = radius * (0.92 if pressed else 1.0)
	draw_circle(center, r, fill)
	draw_arc(center, r, 0, TAU, 48, Color(1, 1, 1, 0.7 if pressed else 0.32), 2.5, true)
	var font: Font = get_theme_default_font()
	var font_size: int = int(rect.size.x * 0.22)
	var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
	var label_color := Color(1, 1, 1, 1.0) if pressed else Color(1, 1, 1, 0.9)
	draw_string(font,
		center - Vector2(text_size.x / 2.0, -font_size / 3.0),
		label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, label_color)
