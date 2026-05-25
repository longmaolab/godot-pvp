extends SceneTree
## Wall collision regression — does the player block on map walls?
##
## Hypothesis under test: Jolt physics (3d/physics_engine="JoltPhysics3D")
## does NOT collide with CSGBox3D-generated collision shapes the way default
## Godot Physics does. arena-shooter-3d uses default physics and walls work;
## godot-pvp uses Jolt and the user reports "随便走都能穿".
##
## Setup: load blank.tscn (boundary walls at ±30, thickness 1, height 4),
## spawn a player near the south wall, walk forward for 2s. Player should
## be blocked at z ≈ -29.5 (wall is at z=-30, capsule radius 0.35).
##
## Run: bash tests/run_wall_collision_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const MAP_SCENE := "res://shared/scenes/maps/blank.tscn"

const INPUT_FORWARD := 1 << 0  # NetProtocol.INPUT_FORWARD
const INPUT_BACK := 1 << 1

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var map: Node = (load(MAP_SCENE) as PackedScene).instantiate()
	root.add_child(map)
	await physics_frame
	await physics_frame  # let CSG bake collision

	# Spawn player 5m south of north wall (north wall at z=-30, player at z=-25).
	var p: Node = (load(PLAYER_SCENE) as PackedScene).instantiate()
	p.is_local = false
	p.is_human_input = false
	p.use_remote_input = true
	root.add_child(p)
	p.global_position = Vector3(0, 1.0, -25.0)
	await physics_frame
	await physics_frame  # let gravity settle

	# Walk forward (toward -Z, i.e. into north wall).
	# input_z = float(BACK) - float(FORWARD). FORWARD → input_z = -1.
	# dir = transform.basis * Vector3(0, 0, -1). At spawn yaw=0, that's -Z.
	p._remote_input_bits = INPUT_FORWARD

	# 2 seconds at move_speed=5 → 10m of attempted travel.
	# Player starts at z=-25, wall at z=-30. Should hit wall after 5m.
	var elapsed: float = 0.0
	var samples: Array[float] = []
	while elapsed < 2.0:
		await physics_frame
		elapsed += 1.0 / 60.0
		if int(elapsed * 60.0) % 30 == 0:
			samples.append(p.global_position.z)

	p._remote_input_bits = 0
	var final_z: float = p.global_position.z
	var final_y: float = p.global_position.y

	print("[wall-test] z samples (every 0.5s): %s" % str(samples))
	print("[wall-test] final pos: z=%.3f y=%.3f" % [final_z, final_y])

	# Wall at z=-30 (1m thick centered → z spans -30.5 to -29.5).
	# Capsule radius 0.35 → player center should stop at z >= -29.5 + 0.35 = -29.15.
	# Generous threshold: anything z > -30 means hasn't gone through.
	if final_z < -30.0:
		failures.append("player walked through north wall: z=%.3f (wall at z=-30, should block at z >= -29.15)" % final_z)
	if final_y < -1.0:
		failures.append("player fell through floor: y=%.3f" % final_y)

	if failures.is_empty():
		print("[wall-test] PASS — player stopped at z=%.2f (wall blocks correctly)" % final_z)
		quit(0)
	else:
		for f in failures:
			print("[wall-test] FAIL — " + f)
		quit(1)
