extends SceneTree
## Footstep cadence test. Footsteps are distance-accumulated (a step every
## FOOTSTEP_STRIDE metres), so they must tick up while a player moves and stay
## flat while still — and crouch-sneaking should stride longer (fewer steps).
## Verifies the trigger logic (the spatial-audio FEEL needs a human's ears).
##
## Run: bash tests/run_footstep_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const INPUT_FORWARD := 1 << 0
const INPUT_CROUCH := 1 << 5

var failures: Array[String] = []
var checks_done: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new(); box.size = Vector3(60, 0.5, 60); fs.shape = box
	floor_body.add_child(fs)
	root.add_child(floor_body)
	floor_body.global_position = Vector3(0, -0.25, 0)

	var p: Node = await _spawn(Vector3(0, 1, 0))

	# Walk forward ~1.5s → several footsteps.
	p._remote_input_bits = INPUT_FORWARD
	await _wait(1.5)
	var walked: int = p.footstep_count
	if walked < 2:
		failures.append("no footsteps while walking (count=%d) — cadence not firing." % walked)
	checks_done += 1

	# Stand still → count must not grow.
	p._remote_input_bits = 0
	await _wait(0.6)   # bleed off residual velocity
	var at_rest: int = p.footstep_count
	await _wait(1.0)
	if p.footstep_count > at_rest:
		failures.append("footsteps fired while standing still (%d → %d)." % [at_rest, p.footstep_count])
	checks_done += 1

	# Crouch-walk the same time/speed → fewer steps than upright (longer stride).
	var c: Node = await _spawn(Vector3(20, 1, 0))
	c._remote_input_bits = INPUT_FORWARD | INPUT_CROUCH
	await _wait(1.5)
	var upright_steps: int = walked
	var crouch_steps: int = c.footstep_count
	# crouch speed is slower AND stride longer, so it should be clearly fewer.
	if crouch_steps >= upright_steps:
		failures.append("crouch-walk wasn't quieter: %d steps vs upright %d." % [crouch_steps, upright_steps])
	checks_done += 1

	_finish("walked=%d, rest=%d→%d, crouch=%d" % [walked, at_rest, p.footstep_count, crouch_steps])


func _spawn(pos: Vector3) -> Node:
	var p: Node = (load(PLAYER_SCENE) as PackedScene).instantiate()
	p.is_local = true
	p.is_human_input = false
	p.use_remote_input = true
	root.add_child(p)
	p.global_position = pos
	await physics_frame
	return p


func _wait(t: float) -> void:
	var e: float = 0.0
	while e < t:
		await physics_frame
		e += 1.0 / 60.0


func _finish(summary: String) -> void:
	print("[footstep] %s" % summary)
	if failures.is_empty():
		print("  PASS — %d checks: steps while moving, silent at rest, crouch quieter" % checks_done)
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
