extends SceneTree
## Trenches-map collision. User reports walking through walls in trenches
## (especially "can't go up slopes"). Trenches has no actual slopes — only
## trench-front walls 3m tall. Test: can player walk into a wall and end
## up on the other side?

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const MAP_SCENE := "res://shared/scenes/maps/trenches.tscn"

const INPUT_FORWARD := 1 << 0
const INPUT_BACK := 1 << 1
const INPUT_JUMP := 1 << 4
const INPUT_RIGHT := 1 << 3

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var map: Node = (load(MAP_SCENE) as PackedScene).instantiate()
	root.add_child(map)
	await _wait(0.05)

	# TrenchN_Front: (0, 1, -5.5), size (120, 3, 1) → z=[-6, -5], y=[-0.5, 2.5]
	# Player on GroundN (top y=0) at z=-4 trying to walk south (toward +Z)
	# into the wall at z=-5. Wait — GroundN center z=-20, so at z=-4 you're
	# off the north ground onto NoMansLand. Let me reposition:
	# GroundN spans z in [-35, -5]. Player at (0, 1, -7) is on GroundN, 1m north of TrenchN_Front.
	var p: Node = _make_player(Vector3(0.0, 1.0, -7.0))
	await _wait(0.3)  # settle
	var start_y: float = p.global_position.y
	print("[trench] spawned on GroundN settled to y=%.3f (ground top is 0.0)" % start_y)

	# Walk south (INPUT_BACK = +Z) into TrenchN_Front wall at z=-5.5 (north face z=-6).
	# Capsule radius 0.35 → should stop at z = -6 - 0.35 = -6.35.
	p._remote_input_bits = INPUT_BACK
	await _wait(2.0)
	p._remote_input_bits = 0
	var end_pos: Vector3 = p.global_position
	print("[trench] south-walk into TrenchN_Front end pos=%s (expected z >= -6.35)" % str(end_pos))
	if end_pos.z < -6.0:
		failures.append("walked through TrenchN_Front wall: z=%.3f (wall face at z=-6, expected stop z >= -6.35)" % end_pos.z)

	# Now try to jump+walk into the wall. Sometimes capsule's bottom hemisphere
	# can clip if you're mid-air pushing into a corner.
	p.global_position = Vector3(0.0, 1.0, -7.0)
	p.velocity = Vector3.ZERO
	await _wait(0.3)
	# Jump and push south simultaneously
	p._remote_input_bits = INPUT_BACK | INPUT_JUMP
	await _wait(0.1)
	p._remote_input_bits = INPUT_BACK
	await _wait(2.0)
	p._remote_input_bits = 0
	var jump_end: Vector3 = p.global_position
	print("[trench] jump+south into wall end pos=%s" % str(jump_end))
	if jump_end.z < -6.0:
		failures.append("jump+walked through TrenchN_Front wall: z=%.3f" % jump_end.z)

	# Diagonal approach to corner: walk SOUTH-EAST into trench wall + east wall corner.
	# East wall WallE at x=60, so corner at (60-, -5.5). Far from spawn — too long.
	# Use shorter scenario: walk into the wall AT ANGLE.
	p.global_position = Vector3(0.0, 1.0, -7.0)
	p.velocity = Vector3.ZERO
	await _wait(0.3)
	p._remote_input_bits = INPUT_BACK | INPUT_RIGHT
	await _wait(2.0)
	p._remote_input_bits = 0
	var diag: Vector3 = p.global_position
	print("[trench] diagonal south+east end pos=%s" % str(diag))
	if diag.z < -6.0:
		failures.append("diagonal walked through wall: z=%.3f" % diag.z)

	# Try the GAP at x=-30 (Gap1, subtraction at (-30, 1, -5.5) size 3x3x1.5).
	# If CSG subtraction actually works, walking south at x=-30 should pass through.
	# If subtraction is ignored (sibling CSGs don't compose), the wall is still solid.
	p.global_position = Vector3(-30.0, 1.0, -7.0)
	p.velocity = Vector3.ZERO
	await _wait(0.3)
	p._remote_input_bits = INPUT_BACK
	await _wait(2.0)
	p._remote_input_bits = 0
	var gap_pos: Vector3 = p.global_position
	print("[trench] walk south at x=-30 (Gap1 location) end pos=%s" % str(gap_pos))
	print("        — if CSG subtraction works, expect z < -6 (passed through gap)")
	print("        — if not, expect z stops near -6.35 (wall solid)")

	if failures.is_empty():
		print("[trench] PASS — no through-wall observed in tested scenarios")
		quit(0)
	else:
		for f in failures:
			print("[trench] FAIL — " + f)
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
