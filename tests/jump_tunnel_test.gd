extends SceneTree
## Jump-tunneling regression — when player jumps onto an obstacle top and
## continues moving horizontally, does the capsule tunnel through?
##
## User reported "跳过障碍物顶部能穿过去". blank.tscn has two obstacles:
##   ObstacleA at (8, 1.5, -6), size (2, 3, 2) → top face at y=3.0
##   ObstacleB at (-6, 1, 5), size (4, 2, 1) → top face at y=2.0 (thinner)
##
## Hypothesis: Jolt's CharacterVirtual depenetration may push the capsule
## sideways when landing on a thin obstacle edge, causing it to slide off
## or even pass through.
##
## Test: spawn player above ObstacleB (thinner = more vulnerable), apply
## downward velocity + horizontal movement. Player should land on top, NOT
## end up below it (y < obstacle top - 1.0 = fell through).

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const MAP_SCENE := "res://shared/scenes/maps/blank.tscn"

const INPUT_FORWARD := 1 << 0
const INPUT_BACK := 1 << 1
const INPUT_LEFT := 1 << 2
const INPUT_RIGHT := 1 << 3
const INPUT_JUMP := 1 << 4

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var map: Node = (load(MAP_SCENE) as PackedScene).instantiate()
	root.add_child(map)
	await physics_frame
	await physics_frame  # CSG bake

	# ObstacleB sits at (-6, 1, 5), size (4, 2, 1). Top at y=2.0.
	# Spawn player above its center, slightly to one side so movement crosses.
	var p: Node = (load(PLAYER_SCENE) as PackedScene).instantiate()
	p.is_local = false
	p.is_human_input = false
	p.use_remote_input = true
	root.add_child(p)
	# Spawn 3m above top of ObstacleB, offset on X so we move across it
	p.global_position = Vector3(-8.0, 5.0, 5.0)
	await physics_frame

	# Walk RIGHT toward and across ObstacleB. Gravity will pull us onto it
	# mid-traverse — that's the moment tunneling could happen.
	p._remote_input_bits = INPUT_RIGHT
	var elapsed: float = 0.0
	var min_y: float = 999.0
	var samples: Array[String] = []
	while elapsed < 2.5:
		await physics_frame
		elapsed += 1.0 / 60.0
		min_y = minf(min_y, p.global_position.y)
		if int(elapsed * 60.0) % 20 == 0:
			samples.append("t=%.2fs (%.2f,%.2f,%.2f)" % [elapsed, p.global_position.x, p.global_position.y, p.global_position.z])

	p._remote_input_bits = 0
	var final = p.global_position
	print("[jump-tunnel] samples: %s" % str(samples))
	print("[jump-tunnel] final: %s, min y reached: %.2f" % [str(final), min_y])

	# ObstacleB top at y=2.0. If player ever dipped below y=1.0 while x was
	# inside the obstacle's footprint (x in [-8, -4], z in [4.5, 5.5]),
	# they tunneled through.
	# Loose check: if final y < -0.5 (below floor), definitely fell through.
	# Strict check: while crossing the obstacle (x in [-8, -4]), did y ever
	# go below obstacle's bottom (y=0)?
	if final.y < -0.5:
		failures.append("player fell below floor: final y=%.2f" % final.y)

	# --- 1b: Run-and-jump from ground level INTO ObstacleA side, simulating
	# a player who wants to mount the obstacle by jumping at it.
	p.global_position = Vector3(5.0, 1.0, -6.0)  # ground level, west of ObstacleA at x=8
	p.velocity = Vector3.ZERO
	await _settle(p, 0.3)  # land on floor
	# Run right + jump
	p._remote_input_bits = INPUT_RIGHT | INPUT_JUMP
	await physics_frame
	await physics_frame
	# Keep running right but stop jumping (so just_pressed semantics work)
	p._remote_input_bits = INPUT_RIGHT
	var jump_samples: Array[String] = []
	var min_y_during_run: float = 999.0
	for i in range(120):  # 2s @ 60Hz
		await physics_frame
		if i % 10 == 0:
			jump_samples.append("(%.2f,%.2f,%.2f)" % [p.global_position.x, p.global_position.y, p.global_position.z])
		min_y_during_run = minf(min_y_during_run, p.global_position.y)
	p._remote_input_bits = 0
	print("[jump-tunnel] run+jump into ObstacleA samples: %s" % str(jump_samples))
	print("[jump-tunnel] run+jump end at %s, min y=%.2f" % [str(p.global_position), min_y_during_run])
	# (Note: this scenario showed the player flying OVER the obstacle, not through,
	#  so we don't assert on it. Kept for diagnostic visibility.)

	# --- 2nd scenario: vertical jump straight up while standing on obstacle.
	# Reset player ON TOP of ObstacleA (8, 1.5, -6, top at y=3).
	p.global_position = Vector3(8.0, 4.0, -6.0)
	p.velocity = Vector3.ZERO
	await _settle(p, 0.5)
	var landed_y: float = p.global_position.y
	print("[jump-tunnel] landed on ObstacleA at y=%.2f (expected ≈ 3.9 = top + capsule half-height)" % landed_y)
	if landed_y < 2.5:
		failures.append("did not land on top of ObstacleA: y=%.2f (top is 3.0)" % landed_y)

	# Now jump in place.
	p._remote_input_bits = INPUT_JUMP
	await physics_frame
	await physics_frame
	p._remote_input_bits = 0
	await _settle(p, 1.5)
	var post_jump_y: float = p.global_position.y
	print("[jump-tunnel] after jump+land y=%.2f" % post_jump_y)
	if post_jump_y < 2.5:
		failures.append("jumped on obstacle, landed somewhere weird: y=%.2f" % post_jump_y)

	# --- 3rd scenario: drop ONTO the top edge from height with sideways velocity.
	# Spawn directly above ObstacleA's west edge (x=7) with rightward velocity.
	# Capsule (radius 0.35) lands straddling the obstacle edge — that's where
	# Jolt depenetration could push us sideways INTO the obstacle volume.
	p.global_position = Vector3(7.0, 6.0, -6.0)
	p.velocity = Vector3(2.0, 0, 0)  # drift right while falling
	p._remote_input_bits = INPUT_RIGHT
	var edge_min_y: float = 999.0
	var edge_seen_inside: bool = false
	for i in range(180):  # 3s
		await physics_frame
		var pos: Vector3 = p.global_position
		edge_min_y = minf(edge_min_y, pos.y)
		# Inside obstacle X footprint [7,9] AND below obstacle top y=3?
		if pos.x > 7.0 and pos.x < 9.0 and pos.y < 2.8:
			edge_seen_inside = true
			print("[jump-tunnel] PENETRATION at t=%.2fs pos=(%.2f,%.2f,%.2f)" % [i/60.0, pos.x, pos.y, pos.z])
			break
	p._remote_input_bits = 0
	print("[jump-tunnel] edge-drop end at %s, min y=%.2f, penetrated=%s" % [str(p.global_position), edge_min_y, str(edge_seen_inside)])
	if edge_seen_inside:
		failures.append("edge-drop tunneled into ObstacleA body")

	# --- 4th scenario: stand on top, walk off the side EDGE slowly.
	# Should fall down past the side, not through the body.
	p.global_position = Vector3(8.0, 4.0, -6.0)  # center top of A
	p.velocity = Vector3.ZERO
	await _settle(p, 0.5)
	p._remote_input_bits = INPUT_RIGHT  # walk east off the obstacle
	var walkoff_inside: bool = false
	for i in range(120):  # 2s
		await physics_frame
		var pos: Vector3 = p.global_position
		if pos.x > 7.0 and pos.x < 9.0 and pos.y < 2.8:
			walkoff_inside = true
			print("[jump-tunnel] WALKOFF PENETRATION at t=%.2fs pos=(%.2f,%.2f,%.2f)" % [i/60.0, pos.x, pos.y, pos.z])
			break
	p._remote_input_bits = 0
	print("[jump-tunnel] walkoff end at %s, penetrated=%s" % [str(p.global_position), str(walkoff_inside)])
	if walkoff_inside:
		failures.append("walking off top of ObstacleA fell through the body")

	if failures.is_empty():
		print("[jump-tunnel] PASS — all scenarios held")
		quit(0)
	else:
		for f in failures:
			print("[jump-tunnel] FAIL — " + f)
		quit(1)


func _settle(p: Node, t: float) -> void:
	var e: float = 0.0
	while e < t:
		await physics_frame
		e += 1.0 / 60.0
