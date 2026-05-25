extends SceneTree
## Geometry regression test for player hitboxes.
##
## Background: a previous fix in 2026-05-25 shrank the BodyHitbox to match
## the procedural box character. But the GLB skins were scaled 1.85× on top
## of that, so the *visible* character ended up entirely above the
## hitboxes — kids reported "瞄准身体打不中 / 爆不了头". The follow-up
## fix replaced the constant scale with per-skin SKIN_SCALES + bumped the
## head sphere radius. This test pins the alignment so the next refactor
## of player.tscn or apply_skin() can't silently break it again.
##
## Strategy: spawn 1 target, raycast from a fixed shooter eye at three
## sentinel pitches per skin, expect specific hit results. Bypasses the
## try_fire pipeline (no cooldown, no network) — pure geometry.
##
## Run: bash tests/run_hitbox_geometry_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const SHOOTER_EYE := Vector3(10.0, 1.9, 10.0)   # root Y=0.9 + Head local Y=1.0
const TARGET_POS := Vector3(0.0, 0.9, 0.0)
const SHOOT_MASK := 4                             # hitboxes are on layer 4
const SKIN_COUNT := 18

var failures: Array[String] = []
var checks: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: PackedScene = load(PLAYER_SCENE) as PackedScene
	assert(scene != null, "couldn't load player.tscn")

	var target: Node3D = scene.instantiate() as Node3D
	root.add_child(target)
	target.global_position = TARGET_POS
	await physics_frame
	await physics_frame

	var horizontal: Vector3 = TARGET_POS - SHOOTER_EYE
	horizontal.y = 0.0
	var dist: float = horizontal.length()
	var forward: Vector3 = horizontal / dist
	var space: PhysicsDirectSpaceState3D = root.get_world_3d().direct_space_state

	for idx in range(SKIN_COUNT):
		target.call("apply_skin", idx)
		await physics_frame
		await physics_frame
		# Snap the target back to TARGET_POS *after* the physics frames —
		# the player_controller applies gravity each tick (target was
		# drifting downward 3 cm per skin, which moved HeadHitbox out of
		# the shooter's eye-level ray and gave a false-positive failure).
		target.global_position = TARGET_POS
		if target is CharacterBody3D:
			(target as CharacterBody3D).velocity = Vector3.ZERO
		PhysicsServer3D.body_set_state(target.get_rid(),
			PhysicsServer3D.BODY_STATE_TRANSFORM, target.global_transform)
		_check_skin(idx, space, forward, dist)

	print("\n=== SUMMARY: %d checks, %d failures ===" % [checks, failures.size()])
	if failures.is_empty():
		print("  PASS — hitbox geometry covers visible model")
		quit(0)
	else:
		print("  FAIL —")
		for f in failures:
			print("    - %s" % f)
		quit(1)


func _check_skin(idx: int, space: PhysicsDirectSpaceState3D,
		forward: Vector3, dist: float) -> void:
	# Pitch = 0: dead-level aim. Both shooter eye and target eye are at
	# world Y=1.9 (Head node local Y=+1.0). The HeadHitbox sphere is
	# centered at +1.0 too. This is the most basic sanity check —
	# if pitch 0 misses, the hitbox is fundamentally detached from where
	# the camera/eye sits.
	var r_eye: StringName = _cast(space, forward, 0.0, dist)
	if r_eye != &"HEAD":
		failures.append("skin %2d: pitch=0 (eye→eye level) expected HEAD, got %s" %
			[idx, str(r_eye)])
	# Pitch = ~-3.7°: 0.92m below shooter eye at target → world Y ≈ 0.98,
	# clearly inside the visible torso AND inside BodyHitbox capsule [0, 1.8].
	var r_chest: StringName = _cast(space, forward, -atan2(0.92, dist), dist)
	if r_chest != &"BODY":
		failures.append("skin %2d: pitch chest-level expected BODY, got %s" %
			[idx, str(r_chest)])
	# Pitch = ~+8°: aims 2 m ABOVE the target's eye → world Y ≈ 3.9. Even
	# the tallest skin's head mesh AABB tops out around 3.3 m, so anything
	# this high MUST miss. Catches the class of bug where a hitbox is
	# accidentally placed in the air above characters.
	var r_air: StringName = _cast(space, forward, atan2(2.0, dist), dist)
	if r_air != &"MISS":
		failures.append("skin %2d: pitch 2 m above eye expected MISS, got %s" %
			[idx, str(r_air)])
	checks += 3
	print("[skin %2d] eye→%s  chest→%s  air→%s" %
		[idx, str(r_eye), str(r_chest), str(r_air)])


func _cast(space: PhysicsDirectSpaceState3D, forward: Vector3,
		pitch: float, dist: float) -> StringName:
	var dir: Vector3 = forward * cos(pitch) + Vector3.UP * sin(pitch)
	var query := PhysicsRayQueryParameters3D.create(
		SHOOTER_EYE, SHOOTER_EYE + dir * (dist + 5.0))
	query.collision_mask = SHOOT_MASK
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return &"MISS"
	var name: String = hit.collider.name
	if name == "HeadHitbox":
		return &"HEAD"
	if name == "BodyHitbox":
		return &"BODY"
	return StringName(name)
