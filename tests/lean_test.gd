extends SceneTree
## Lean / peek test — pins the FAIRNESS-critical behavior of the lean system so
## it can ship without an in-browser playtest:
##
##   A. Holding lean-right shifts the HEAD HITBOX to the player's right (and
##      rolls the view). This is what makes a peek fair — the server resolves
##      hits against head_hitbox, so it must move with the visible head.
##   B. Lean-left mirrors it to the left.
##   C. Releasing returns the hitbox to center.
##   D. Lean is gated while sprinting (no peek-strafing).
##   E. set_remote_lean (the path remote enemies take from snapshot flags)
##      drives the same offset — so what a client SEES matches the hitbox.
##
## The on-screen look (roll amount, model tilt) still needs a human glance.
## Run: bash tests/run_lean_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const INPUT_SPRINT := 1 << 6
const INPUT_LEAN_LEFT := 1 << 16
const INPUT_LEAN_RIGHT := 1 << 17

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
	box.size = Vector3(20, 0.5, 20)
	fs.shape = box
	floor_body.add_child(fs)
	root.add_child(floor_body)
	floor_body.global_position = Vector3(0, -0.25, 0)

	var p: Node = await _spawn_driver(Vector3(0, 1, 0))
	if p == null:
		_finish("could not instantiate player")
		return
	var full: float = p.LEAN_OFFSET
	var hitbox: Node3D = p.get_node_or_null(^"HeadHitbox") as Node3D
	if hitbox == null:
		_finish("player has no HeadHitbox")
		return

	# ── A. Lean right → hitbox shifts +x, view rolls ────────────────────────
	p._remote_input_bits = INPUT_LEAN_RIGHT
	await _wait_seconds(0.45)
	var x_right: float = hitbox.position.x
	var roll_right: float = absf((p.get_node(^"Head") as Node3D).rotation.z)
	if x_right < full * 0.6:
		failures.append("A: head hitbox didn't shift right on lean (x=%.2f, full=%.2f). Peek wouldn't be hittable where drawn." % [x_right, full])
	if roll_right < 0.04:
		failures.append("A: view didn't roll into the lean (head.z=%.3f)." % roll_right)
	checks_done += 1

	# ── B. Lean left → hitbox shifts -x ─────────────────────────────────────
	p._remote_input_bits = INPUT_LEAN_LEFT
	await _wait_seconds(0.45)
	var x_left: float = hitbox.position.x
	if x_left > -full * 0.6:
		failures.append("B: head hitbox didn't shift left on lean (x=%.2f)." % x_left)
	checks_done += 1

	# ── C. Release → returns to center ──────────────────────────────────────
	p._remote_input_bits = 0
	await _wait_seconds(0.5)
	var x_center: float = hitbox.position.x
	if absf(x_center) > 0.06:
		failures.append("C: head hitbox didn't recenter after releasing lean (x=%.2f)." % x_center)
	checks_done += 1

	# ── D. Gated while sprinting ────────────────────────────────────────────
	p._remote_input_bits = INPUT_LEAN_RIGHT | INPUT_SPRINT
	await _wait_seconds(0.4)
	var x_sprint: float = hitbox.position.x
	if absf(x_sprint) > 0.12:
		failures.append("D: leaned while sprinting (x=%.2f) — should be gated." % x_sprint)
	checks_done += 1
	p._remote_input_bits = 0
	await _wait_seconds(0.4)

	# ── E. Remote path: set_remote_lean drives the same offset ──────────────
	var r: Node = await _spawn_remote(Vector3(6, 1, 0))
	if r == null:
		failures.append("E: could not spawn remote-style player")
	else:
		r.set_remote_lean(1)
		await _wait_seconds(0.45)
		var rhit: Node3D = r.get_node_or_null(^"HeadHitbox") as Node3D
		var rx: float = rhit.position.x if rhit != null else 0.0
		if rx < full * 0.6:
			failures.append("E: set_remote_lean didn't offset the hitbox (x=%.2f) — remote peek wouldn't match what we shoot at." % rx)
		if r.lean_sign() != 1:
			failures.append("E: lean_sign() wrong after set_remote_lean(1): %d" % r.lean_sign())
		checks_done += 1

	_finish("right x=%.2f roll=%.3f | left x=%.2f | center x=%.2f | sprint-gated x=%.2f" \
		% [x_right, roll_right, x_left, x_center, x_sprint])


func _spawn_driver(pos: Vector3) -> Node:
	var scene: PackedScene = load(PLAYER_SCENE) as PackedScene
	if scene == null:
		return null
	var p: Node = scene.instantiate()
	p.is_local = true
	p.is_human_input = false
	p.use_remote_input = true   # _step_movement reads _remote_input_bits → sets _lean_target
	root.add_child(p)
	p.global_position = pos
	await physics_frame
	return p


func _spawn_remote(pos: Vector3) -> Node:
	var scene: PackedScene = load(PLAYER_SCENE) as PackedScene
	if scene == null:
		return null
	var p: Node = scene.instantiate()
	p.is_local = false          # remote enemy: driven only by set_remote_lean
	p.is_human_input = false
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
	print("[lean-test] %s" % summary)
	if failures.is_empty():
		print("  PASS — %d checks ok: hitbox follows the peek both ways, recenters, sprint-gated, remote path works" % checks_done)
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
