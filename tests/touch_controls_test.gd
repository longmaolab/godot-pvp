extends SceneTree
## Touch-overlay wiring test. The on-device FEEL needs a real phone, but this
## verifies the input plumbing: tapping FIRE presses the fire action, the left-
## zone joystick presses movement, and a right-zone drag drives the player's
## aim via apply_touch_look. Drives the handlers directly (bypassing the
## _is_touch_device gate that hides it on desktop).
##
## Run: bash tests/run_touch_controls_test.sh

const TOUCH_SCENE := "res://client/scenes/hud/touch_controls.tscn"
const PLAYER_SCENE := "res://shared/scenes/player.tscn"

var failures: Array[String] = []
var checks_done: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# A real local-human player → joins the "local_player" group the overlay queries.
	var p: Node = (load(PLAYER_SCENE) as PackedScene).instantiate()
	p.is_local = true
	p.is_human_input = true
	root.add_child(p)
	await physics_frame

	var tc_root: Node = (load(TOUCH_SCENE) as PackedScene).instantiate()
	root.add_child(tc_root)
	var ov: Control = tc_root.get_node("Overlay")
	# Force-enable (desktop headless would hide it) and lay out for the viewport.
	ov.visible = true
	ov.call("_recalc_layout")
	await physics_frame
	var vp: Vector2 = ov.get_viewport().get_visible_rect().size
	if vp.x < 50.0 or vp.y < 50.0:
		_finish("viewport too small to place touches (%.0fx%.0f) — can't run" % [vp.x, vp.y])
		return

	# ── A. FIRE button presses/releases the fire action ─────────────────────
	var fire_center: Vector2 = ov.get("_fire_rect").get_center()
	ov.call("_handle_touch", _touch(fire_center, 0, true))
	if not Input.is_action_pressed(&"fire"):
		failures.append("A: tapping FIRE didn't press the fire action.")
	ov.call("_handle_touch", _touch(fire_center, 0, false))
	if Input.is_action_pressed(&"fire"):
		failures.append("A: releasing FIRE didn't release the fire action.")
	checks_done += 1

	# ── B. Left-zone joystick drag presses movement ─────────────────────────
	var move_origin := Vector2(vp.x * 0.12, vp.y * 0.6)
	ov.call("_handle_touch", _touch(move_origin, 1, true))
	# Drag straight up → forward.
	ov.call("_handle_drag", _drag(move_origin + Vector2(0, -200), 1))
	if not Input.is_action_pressed(&"move_forward"):
		failures.append("B: pushing the joystick up didn't press move_forward.")
	ov.call("_handle_touch", _touch(move_origin + Vector2(0, -200), 1, false))
	if Input.is_action_pressed(&"move_forward"):
		failures.append("B: releasing the joystick didn't release move_forward.")
	checks_done += 1

	# ── C. Right-zone drag aims via apply_touch_look ────────────────────────
	# Upper-right open area: right of the move zone, above the bottom button
	# cluster + weapon chips.
	var look_start := Vector2(vp.x * 0.6, vp.y * 0.22)
	var yaw0: float = p._aim_yaw
	ov.call("_handle_touch", _touch(look_start, 2, true))
	ov.call("_handle_drag", _drag(look_start + Vector2(120, 0), 2))
	if is_equal_approx(p._aim_yaw, yaw0):
		failures.append("C: dragging the look zone didn't change aim (apply_touch_look not wired).")
	ov.call("_handle_touch", _touch(look_start + Vector2(120, 0), 2, false))
	checks_done += 1

	_finish("fire press/release ok, joystick→move ok, look drag moved aim %.3f→%.3f" % [yaw0, p._aim_yaw])


func _touch(pos: Vector2, idx: int, pressed: bool) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.position = pos
	e.index = idx
	e.pressed = pressed
	return e


func _drag(pos: Vector2, idx: int) -> InputEventScreenDrag:
	var e := InputEventScreenDrag.new()
	e.position = pos
	e.index = idx
	return e


func _finish(summary: String) -> void:
	print("[touch] %s" % summary)
	if failures.is_empty():
		print("  PASS — %d checks: fire/move/look touch inputs wired to actions + aim" % checks_done)
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
