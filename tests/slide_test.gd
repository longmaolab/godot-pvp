extends SceneTree
## Slide movement-tech test. Drives a player via the use_remote_input bit-field
## (Input.* is unavailable headless) and asserts the slide state machine in
## player_controller._step_movement behaves:
##
##   A. Sprinting forward then TAPPING crouch fires a slide — horizontal speed
##      jumps above sprint speed (the lunge).
##   B. The slide decays — by the end of SLIDE_DURATION speed has dropped to
##      ~crouch speed.
##   C. The head dips during the slide (low profile / smaller target).
##   D. Crouch from a STANDSTILL (no sprint) does NOT slide — it's just a crouch.
##
## Run: bash tests/run_slide_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const SPAWN_Y := 1.0
const INPUT_FORWARD := 1 << 0
const INPUT_CROUCH := 1 << 5
const INPUT_SPRINT := 1 << 6

var failures: Array[String] = []
var checks_done: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(120, 0.5, 120)
	fs.shape = box
	floor_body.add_child(fs)
	root.add_child(floor_body)
	floor_body.global_position = Vector3(0, -0.25, 0)

	var p: Node = await _spawn_driver(Vector3(0, SPAWN_Y, 0))
	if p == null:
		_finish("could not instantiate player")
		return
	var sprint_speed: float = p.move_speed * p.sprint_multiplier
	var crouch_speed: float = p.move_speed * p.CROUCH_SPEED_MULT

	# ── Build up to sprint speed (forward + sprint, NO crouch) ──────────────
	p._remote_input_bits = INPUT_FORWARD | INPUT_SPRINT
	await _wait_seconds(0.6)
	var v_sprint: float = _hspeed(p)
	if v_sprint < sprint_speed * 0.8:
		failures.append("did not reach sprint speed before slide: %.1f (sprint=%.1f)" % [v_sprint, sprint_speed])
	checks_done += 1

	# ── A. Tap crouch (add the bit) → slide lunge ───────────────────────────
	p._remote_input_bits = INPUT_FORWARD | INPUT_SPRINT | INPUT_CROUCH
	await physics_frame
	await physics_frame
	var v_slide: float = _hspeed(p)
	if v_slide <= sprint_speed + 0.3:
		failures.append("A: tapping crouch while sprinting did not lunge — speed %.1f, expected > sprint %.1f. Slide not triggering." % [v_slide, sprint_speed])
	checks_done += 1

	# ── B + C. Let the slide play out; track lowest head height seen ────────
	# (Head eases down over CROUCH_LERP, so sample the minimum across the whole
	# slide rather than one early frame.)
	var head: Node3D = p.get_node_or_null(^"Head") as Node3D
	var head_min_y: float = head.position.y if head != null else p.STAND_HEAD_Y
	var elapsed: float = 0.0
	while elapsed < p.SLIDE_DURATION + 0.15:
		await physics_frame
		elapsed += 1.0 / 60.0
		if head != null:
			head_min_y = minf(head_min_y, head.position.y)
	# C. Head dipped to roughly crouch height at some point during the slide.
	if head != null and head_min_y > (p.STAND_HEAD_Y + p.CROUCH_HEAD_Y) * 0.5:
		failures.append("C: head never dipped below midpoint during slide (min y=%.2f, stand=%.2f, crouch=%.2f). Low profile missing." % [head_min_y, p.STAND_HEAD_Y, p.CROUCH_HEAD_Y])
	checks_done += 1
	# B. Slide decayed back toward crouch speed.
	var v_after: float = _hspeed(p)
	if v_after > sprint_speed * 0.9:
		failures.append("B: slide never decayed — still %.1f after %.2fs (crouch=%.1f). Speed stuck high." % [v_after, p.SLIDE_DURATION, crouch_speed])
	checks_done += 1

	# ── D. Crouch from standstill is NOT a slide ────────────────────────────
	var d: Node = await _spawn_driver(Vector3(40, SPAWN_Y, 0))
	d._remote_input_bits = INPUT_CROUCH            # crouch, no sprint, from rest
	await _wait_seconds(0.25)
	var v_standcrouch: float = _hspeed(d)
	if v_standcrouch > crouch_speed + 1.0:
		failures.append("D: standstill crouch produced a slide burst (%.1f). Edge/sprint gate broken." % v_standcrouch)
	checks_done += 1

	_finish("sprint=%.1f → lunge=%.1f → after=%.1f (crouch=%.1f); standstill-crouch=%.1f" \
		% [v_sprint, v_slide, v_after, crouch_speed, v_standcrouch])


func _hspeed(p: Node) -> float:
	return Vector2(p.velocity.x, p.velocity.z).length()


func _spawn_driver(pos: Vector3) -> Node:
	var scene: PackedScene = load(PLAYER_SCENE) as PackedScene
	if scene == null:
		return null
	var p: Node = scene.instantiate()
	p.is_local = true
	p.is_human_input = false
	p.use_remote_input = true   # _step_movement reads _remote_input_bits
	root.add_child(p)
	p.global_position = pos
	await physics_frame
	return p


func _wait_seconds(t: float) -> void:
	var elapsed: float = 0.0
	while elapsed < t:
		await physics_frame
		elapsed += 1.0 / 60.0


func _finish(summary: String) -> void:
	print("[slide-test] %s" % summary)
	if failures.is_empty():
		print("  PASS — %d checks ok: lunge fires, decays, head dips, no false-trigger" % checks_done)
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
