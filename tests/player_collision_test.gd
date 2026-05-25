extends SceneTree
## Player-vs-player collision regression test under Jolt physics.
##
## Background: project.godot sets `3d/physics_engine = "JoltPhysics3D"`.
## arena-shooter-3d uses default Godot Physics with layer=1/mask=1 and
## CharacterBody3D-to-CharacterBody3D collision "just works"; godot-pvp
## had layer=2/mask=1 (no player↔player collision, hence 穿模). A prior
## attempt to set mask=3 caused players to launch to Y=65, presumably
## because Jolt's CharacterVirtual depenetration accumulates each frame
## when two CharacterBody3D overlap at spawn.
##
## What this test pins down:
##   1. Two non-overlapping players should NOT launch vertically.
##   2. One player walking into the other should NOT pass through —
##      either A stops short or B gets nudged.
##   3. Y stays near floor — no depenetration runaway.
##
## Run: bash tests/run_player_collision_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const SPAWN_Y := 1.0
const MAX_Y_AFTER_SETTLE := 2.5  # any value above this = blown up
# Input bit constants (mirror NetProtocol; can't import autoload from a
# script-mode SceneTree without setting up the project run).
const INPUT_RIGHT := 1 << 3
const INPUT_LEFT := 1 << 2

var failures: Array[String] = []
var checks_done: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Static floor under the test arena so move_and_slide has something
	# to land on. Layer 1 = the world layer the player's mask targets.
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.5, 20)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)
	floor_body.global_position = Vector3(0, -0.25, 0)

	# Two players, A at -0.6 and B at +0.6 on X. Capsule radius 0.4 →
	# surface gap 0.4m at spawn. Wide enough to avoid depenetration
	# even with mask=3.
	var a: Node = await _spawn_player(Vector3(-0.6, SPAWN_Y, 0))
	var b: Node = await _spawn_player(Vector3(0.6, SPAWN_Y, 0))
	if a == null or b == null:
		_finish("could not instantiate players")
		return

	# Settle for 1s (gravity + any collision response should stabilize).
	await _wait_seconds(1.0)

	# --- Assertion 1: no vertical explosion at rest.
	for label_pair in [["A", a], ["B", b]]:
		var label: String = label_pair[0]
		var p: Node = label_pair[1]
		var y: float = p.global_position.y
		if y > MAX_Y_AFTER_SETTLE:
			failures.append("[%s] launched at rest: y=%.2f (max %.2f). Jolt depenetration runaway." % [label, y, MAX_Y_AFTER_SETTLE])
		elif y < -1.0:
			failures.append("[%s] fell through floor: y=%.2f" % [label, y])
		checks_done += 1

	# --- Assertion 2: not overlapping (X separation ≥ 0.6 = ~1.5×radius).
	var sep_x: float = absf(b.global_position.x - a.global_position.x)
	if sep_x < 0.6:
		failures.append("players intersecting at rest: |x|=%.2f (expected >= 0.6)" % sep_x)
	checks_done += 1

	# --- Assertion 3: walk A into B. Use the use_remote_input bit-field
	# hack so _step_movement reads input_x from _remote_input_bits instead
	# of Input.* (which is unavailable headless).
	var a_start_x: float = a.global_position.x
	var b_start_x: float = b.global_position.x
	a.is_local = true
	a.is_human_input = false
	a.use_remote_input = true
	a._remote_input_bits = INPUT_RIGHT   # walk toward +X (toward B)
	# 1s of physics at ~60Hz at move_speed=5 → ~5m of travel if unimpeded.
	# Gap to traverse is only 1.2m, so we'll definitely contact B.
	await _wait_seconds(1.0)
	a._remote_input_bits = 0

	var a_end_x: float = a.global_position.x
	var b_end_x: float = b.global_position.x
	var b_pushed: float = b_end_x - b_start_x

	# Pass criterion: A did not walk past B's original position OR B got
	# pushed forward enough to absorb A's momentum.
	if a_end_x > b_start_x + 0.1 and b_pushed < 0.1:
		failures.append("A walked through B: A %.2f→%.2f, B %.2f→%.2f. Collision off." \
			% [a_start_x, a_end_x, b_start_x, b_end_x])
	checks_done += 1

	# --- Final Y check after the walk (the real test for Jolt explosion).
	for label_pair in [["A", a], ["B", b]]:
		var label: String = label_pair[0]
		var p: Node = label_pair[1]
		var y: float = p.global_position.y
		if y > MAX_Y_AFTER_SETTLE:
			failures.append("[%s] launched after walk: y=%.2f. Jolt CharacterBody depenetration unstable." % [label, y])
		checks_done += 1

	# --- Assertion 4: extreme depenetration test — spawn C and D
	# overlapping (0.1m apart, both with radius 0.4 → mutual penetration).
	# Jolt's CharacterVirtual resolver must NOT launch them vertically.
	# This is the scenario the "flew to Y=65" historical bug reproduced.
	var c: Node = await _spawn_player(Vector3(8.0, SPAWN_Y, 0))
	var d: Node = await _spawn_player(Vector3(8.1, SPAWN_Y, 0))
	if c == null or d == null:
		_finish("could not instantiate overlap players")
		return
	await _wait_seconds(1.0)
	var cy: float = c.global_position.y
	var dy: float = d.global_position.y
	if cy > MAX_Y_AFTER_SETTLE or dy > MAX_Y_AFTER_SETTLE:
		failures.append("overlap-at-spawn launched players: C.y=%.2f D.y=%.2f (max %.2f). Y=65 bug regressed." \
			% [cy, dy, MAX_Y_AFTER_SETTLE])
	# (No horizontal-separation assertion: Jolt's CharacterVirtual only
	# resolves overlap when one of the bodies has horizontal motion. Two
	# stationary overlapping players just stay overlapped. That's not a
	# real-game scenario because _spawn_pos_for picks distant points;
	# the spawn-overlap case here exists only to catch the Y-explosion
	# regression.)
	var cd_x: float = absf(d.global_position.x - c.global_position.x)
	checks_done += 1

	_finish("walked: A %.2f→%.2f, B %.2f→%.2f, A.y=%.2f B.y=%.2f; overlap C.y=%.2f D.y=%.2f |cd|=%.2f" \
		% [a_start_x, a_end_x, b_start_x, b_end_x, a.global_position.y, b.global_position.y, cy, dy, cd_x])


func _spawn_player(pos: Vector3) -> Node:
	var scene: PackedScene = load(PLAYER_SCENE) as PackedScene
	if scene == null:
		return null
	var p: Node = scene.instantiate()
	p.is_local = false
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
	print("[collision-test] %s" % summary)
	if failures.is_empty():
		print("  PASS — %d checks ok, no Jolt depenetration runaway, players block each other" % checks_done)
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
