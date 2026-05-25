extends Node
## In-process test for the rewind→raycast→restore sequence.
##
## Setup (no actual network, just the host-side machinery):
##   * Build a game world with shooter + target players.
##   * Record an old snapshot of target at position A (in front of shooter).
##   * Move target to position B (off to the side).
##   * Call the host-side fire handler with lag-comp ENABLED and a tuned
##     ping so the rewind targets the A timestamp.
##   * Verify the shot hits (rewind succeeded).
##   * Disable lag-comp and repeat — verify the shot now MISSES (rewind
##     is what made the difference).

const GAME_CONTROLLER := preload("res://client/scripts/game_controller.gd")
const PLAYER_SCENE := preload("res://shared/scenes/player.tscn")
const MAP_SCENE := preload("res://shared/scenes/maps/blank.tscn")
const AK20 := preload("res://shared/data/weapons/ak20.tres")
const LC_SCRIPT := preload("res://server/scripts/lag_compensator.gd")

var failed: int = 0


func _ready() -> void:
	print("\n=== lag_comp integration test (rewind saves the shot) ===")
	await _run_test()
	print("\n=== result: %s (%d failures) ===" % ["PASS" if failed == 0 else "FAIL", failed])
	get_tree().quit(0 if failed == 0 else 1)


func _run_test() -> void:
	# Construct a minimal "host-like" environment by hand. We don't run the
	# full game_controller (it would need a multiplayer peer). Instead we
	# create the same nodes a host scene would have.
	var map: Node3D = MAP_SCENE.instantiate()
	add_child(map)
	var players_root := Node3D.new()
	players_root.name = "Players"
	add_child(players_root)

	var lag_comp: Node = LC_SCRIPT.new()
	add_child(lag_comp)

	# Shooter at fixed spot, aimed straight along +Z.
	var shooter: Node = PLAYER_SCENE.instantiate()
	shooter.weapon_def = AK20
	shooter.is_local = false   # never read input
	players_root.add_child(shooter)
	shooter.global_position = Vector3(0, 1, 0)
	shooter.rotation.y = 0.0   # face -Z is default; we'll aim explicitly below
	shooter.head_hitbox.monitoring = true
	shooter.body_hitbox.monitoring = true

	# Target initially at A = directly in shooter's line of fire.
	var target: Node = PLAYER_SCENE.instantiate()
	target.weapon_def = AK20
	target.is_local = false
	players_root.add_child(target)
	var POS_A: Vector3 = Vector3(0, 1, -10)   # straight ahead of shooter
	var POS_B: Vector3 = Vector3(8, 1, -10)   # off to the side
	target.global_position = POS_A
	target.head_hitbox.monitoring = true
	target.body_hitbox.monitoring = true

	# Aim shooter at POS_A (head height).
	_aim_at(shooter, POS_A + Vector3(0, 1.0, 0))

	# Two physics frames so transforms propagate.
	await get_tree().physics_frame
	await get_tree().physics_frame

	# Record snapshot of target at POS_A at a known "old" timestamp.
	var t_old: float = float(Time.get_ticks_msec())
	lag_comp.record(2, POS_A, target.rotation.y, target.head.rotation.x, t_old)
	# Wait long enough for "now" to be ~150ms later.
	await get_tree().create_timer(0.18).timeout

	# Move target to POS_B (so a raw raycast from shooter would miss).
	target.global_position = POS_B
	# Record current position too so the buffer reflects the live state.
	lag_comp.record(2, POS_B, target.rotation.y, target.head.rotation.x)

	await get_tree().physics_frame

	# Trial 1: lag_comp ON — rewind target to POS_A, raycast should hit.
	var hit_with_comp: bool = await _do_lag_compensated_raycast(shooter, target, lag_comp, 2, t_old + 10.0)
	if not hit_with_comp:
		_fail("with lag-comp ON, expected hit (target rewound to POS_A) but got miss")
		return
	print("  [ok] lag-comp ON: raycast hits rewound target at POS_A")

	# Trial 2: lag_comp OFF — raycast against current POS_B, expect miss.
	var hit_without_comp: bool = await _do_lag_compensated_raycast(shooter, target, null, 2, 0.0)
	if hit_without_comp:
		_fail("with lag-comp OFF, target at POS_B should not be hit but raycast hit something")
		return
	print("  [ok] lag-comp OFF: raycast against current POS_B misses (proves rewind made the difference)")


# Mimics game_controller._on_client_fire_server's rewind+raycast core.
func _do_lag_compensated_raycast(
	shooter: Node,
	target: Node,
	lag_comp,
	target_peer: int,
	rewind_to_ms: float,
) -> bool:
	var saved: Dictionary = {}
	if lag_comp != null:
		var sample = lag_comp.sample_at(target_peer, rewind_to_ms)
		if sample != null:
			saved["pos"] = target.global_position
			saved["yaw"] = target.rotation.y
			saved["pitch"] = target.head.rotation.x
			target.global_position = sample.pos
			target.rotation.y = sample.yaw
			target.head.rotation.x = sample.pitch
			# Hitbox global_transforms are computed from parent; force one
			# physics step so the broadphase sees the move.
			await get_tree().physics_frame

	var origin: Vector3 = shooter.camera.global_position
	var dir: Vector3 = -shooter.camera.global_transform.basis.z
	var space: PhysicsDirectSpaceState3D = shooter.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * 500.0)
	query.collision_mask = (1 << 0) | (1 << 2)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var ex: Array[RID] = [shooter.get_rid(), shooter.head_hitbox.get_rid(), shooter.body_hitbox.get_rid()]
	query.exclude = ex
	var hit: Dictionary = space.intersect_ray(query)

	if lag_comp != null and saved.has("pos"):
		target.global_position = saved["pos"]
		target.rotation.y = saved["yaw"]
		target.head.rotation.x = saved["pitch"]

	if hit.is_empty():
		return false
	var collider: Node = hit.collider
	if collider == null:
		return false
	# A hit on a hitbox of the target counts.
	return collider.has_meta(&"owner_player") and collider.get_meta(&"owner_player") == target


func _aim_at(player: Node, world_target: Vector3) -> void:
	var camera_pos: Vector3 = player.camera.global_position
	var to: Vector3 = world_target - camera_pos
	player.rotation.y = atan2(to.x, to.z) + PI
	var horiz: float = Vector2(to.x, to.z).length()
	player.head.rotation.x = atan2(to.y, horiz)


func _fail(msg: String) -> void:
	push_error("[lag-comp-int] " + msg)
	print("  [FAIL] %s" % msg)
	failed += 1
