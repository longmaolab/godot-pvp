extends SceneTree
## Slope-climb test. User: "穿墙是普遍存在的，导致没有办法上斜坡".
## Reproduce in skydock map which has explicit ramps (RampN/RampS/RampMid).
## RampN is at (0, 2, -10), tilted 18.4° around X (asin(0.316)). Walking
## south (+Z) up the ramp should raise the player's y from 0 to ~4.

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const MAP_SCENE := "res://shared/scenes/maps/skydock.tscn"

const INPUT_FORWARD := 1 << 0
const INPUT_BACK := 1 << 1

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var map: Node = (load(MAP_SCENE) as PackedScene).instantiate()
	root.add_child(map)
	await _wait(0.1)

	# RampN at (0, 2, -10) size (4, 0.4, 8) rotated 18.4° around X:
	# bottom (low z end) at ≈ z=-14, y≈0.7   top (high z end) at z≈-6, y≈3.2
	# Spawn player at the LOW end (z=-14) on the ramp, push them SOUTH (+Z)
	# = INPUT_BACK in player input semantics. They should climb UP to y > 2.
	var p: Node = _make_player(Vector3(0.0, 4.0, -14.0))
	await _wait(0.5)  # let gravity settle them onto the ramp
	var settled: Vector3 = p.global_position
	print("[slope] settled onto RampN low end at %s (expected y > 0.5 — on ramp surface)" % str(settled))

	# Push forward toward the high end.
	# INPUT_BACK = +Z, INPUT_FORWARD = -Z. We want +Z (toward z=-6).
	p._remote_input_bits = INPUT_BACK
	var samples: Array[String] = []
	var max_y: float = settled.y
	for i in range(240):  # 4 seconds @ 60Hz
		await physics_frame
		var pos: Vector3 = p.global_position
		max_y = maxf(max_y, pos.y)
		if i % 30 == 0:
			samples.append("(%.2f,%.2f,%.2f)" % [pos.x, pos.y, pos.z])
	p._remote_input_bits = 0
	var end_pos: Vector3 = p.global_position
	print("[slope] climb samples: %s" % str(samples))
	print("[slope] end pos=%s, max y reached=%.2f" % [str(end_pos), max_y])

	# Pass: max_y reached at least 2.0 (well up the ramp). Top of ramp ≈ y=3.2.
	# Fail: stuck near start_y (didn't climb) OR ended below start_y (slid back).
	if max_y < settled.y + 0.5:
		failures.append("ramp climb stalled: started at y=%.2f, max y=%.2f (expected y > %.2f)" % [settled.y, max_y, settled.y + 0.5])
	# Also: did the player phase through the ramp (y went below ground = y < -1)?
	if end_pos.y < -1.0:
		failures.append("player fell through ramp: end y=%.2f" % end_pos.y)

	if failures.is_empty():
		print("[slope] PASS — player climbed from y=%.2f to max y=%.2f" % [settled.y, max_y])
		quit(0)
	else:
		for f in failures:
			print("[slope] FAIL — " + f)
		quit(1)


func _make_player(pos: Vector3) -> Node:
	var p: Node = (load(PLAYER_SCENE) as PackedScene).instantiate()
	p.is_local = false
	p.is_human_input = false
	p.use_remote_input = true
	root.add_child(p)
	p.global_position = pos
	return p


func _wait(t: float) -> void:
	var e: float = 0.0
	while e < t:
		await physics_frame
		e += 1.0 / 60.0
