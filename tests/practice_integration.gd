extends Node
## End-to-end test for the practice vertical slice.
##
## Run:  godot --headless --path . tests/practice_integration.tscn
##
## Builds a live scene, points the player at a dummy, calls try_fire() and
## asserts dummy HP drops by the right amount for body / head / lethal cases.

const AK20 := preload("res://shared/data/weapons/ak20.tres")
const SG8 := preload("res://shared/data/weapons/sg8.tres")
const PLAYER_SCENE := preload("res://shared/scenes/player.tscn")
const DUMMY_SCENE := preload("res://shared/scenes/dummy_target.tscn")
const MAP_SCENE := preload("res://shared/scenes/maps/blank.tscn")

var failed: int = 0
var completed: bool = false


func _ready() -> void:
	print("\n=== practice mode integration test ===")
	await _run_test()
	completed = true
	# A script error mid-test would skip setting completed=true. Treat that as
	# a failure even if no _fail() call landed.
	if not completed:
		_fail("test aborted before completion (likely runtime script error)")
	print("\n=== result: %s (%d failures) ===" % ["PASS" if failed == 0 else "FAIL", failed])
	get_tree().quit(0 if failed == 0 else 1)


func _run_test() -> void:
	var map: Node3D = MAP_SCENE.instantiate()
	add_child(map)

	var player: Node = PLAYER_SCENE.instantiate()
	player.weapon_def = AK20
	player.is_local = false
	add_child(player)
	player.global_position = Vector3(0, 1.5, 0)
	player.head_hitbox.monitoring = true
	player.body_hitbox.monitoring = true

	var dummy: Node = DUMMY_SCENE.instantiate()
	add_child(dummy)
	dummy.global_position = Vector3(0, 0, -10)

	# Aim at dummy body. PlayerController rotates the body for yaw, head node
	# for pitch. Camera looks down -Z of the head's basis.
	_aim_at(player, dummy.global_position + Vector3(0, 0.8, 0))

	await get_tree().physics_frame
	await get_tree().physics_frame

	if dummy.hp != dummy.max_hp:
		_fail("dummy.hp not at max before shot: %s" % dummy.hp)
		return

	var hp_before: float = dummy.hp
	if not player.try_fire():
		_fail("first try_fire returned false")
		return
	await get_tree().physics_frame

	var expected_after: float = hp_before - 25.0
	if absf(dummy.hp - expected_after) > 0.01:
		_fail("body shot expected hp=%.1f, got %.1f (AK20 dmg=25)" % [expected_after, dummy.hp])
		return
	print("  [ok] body shot: dummy hp %.0f → %.0f" % [hp_before, dummy.hp])

	# Head shot.
	_aim_at(player, dummy.global_position + Vector3(0, 1.7, 0))
	await get_tree().physics_frame

	player.time_until_next_shot = 0.0
	var hp_pre_head: float = dummy.hp
	if not player.try_fire():
		_fail("head try_fire returned false")
		return
	await get_tree().physics_frame
	var expected_head: float = hp_pre_head - 50.0   # 25 × 2 headshot mult
	if absf(dummy.hp - expected_head) > 0.01:
		_fail("head shot expected hp=%.1f, got %.1f" % [expected_head, dummy.hp])
		return
	print("  [ok] head shot: dummy hp %.0f → %.0f (×2)" % [hp_pre_head, dummy.hp])

	# Ammo decremented.
	if player.ammo_in_mag != 28:
		_fail("ammo_in_mag expected 28 after 2 shots, got %d" % player.ammo_in_mag)
		return
	print("  [ok] ammo: %d / %d" % [player.ammo_in_mag, player.ammo_reserve])

	# Lethal: keep firing until dummy goes down.
	_aim_at(player, dummy.global_position + Vector3(0, 0.8, 0))
	await get_tree().physics_frame
	var shots: int = 0
	while not dummy.is_down and shots < 30:
		player.time_until_next_shot = 0.0
		player.try_fire()
		await get_tree().physics_frame
		shots += 1
	if not dummy.is_down:
		_fail("dummy did not go down after %d shots (hp=%.1f)" % [shots, dummy.hp])
		return
	print("  [ok] dummy went down after %d additional body shots" % shots)

	# Weapon switch: equip SG-8, verify weapon_def changed, ammo separately tracked.
	# Loadout must be typed Array[Resource] to match the @export signature.
	var two_gun_loadout: Array[Resource] = [AK20, SG8]
	player.loadout = two_gun_loadout
	# Re-init ammo state for the freshly-added SG8.
	player._ammo_state[SG8.id] = {"in_mag": SG8.magazine, "reserve": SG8.reserve}
	player.equip_slot(1)
	if player.weapon_def != SG8:
		_fail("equip_slot(1) did not switch to SG8 (got %s)" % (player.weapon_def.id if player.weapon_def != null else "<null>"))
		return
	if player.ammo_in_mag != SG8.magazine:
		_fail("after switch, ammo_in_mag expected %d, got %d" % [SG8.magazine, player.ammo_in_mag])
		return
	print("  [ok] equip_slot(1): switched to SG-8 with full mag (%d / %d)" % [player.ammo_in_mag, player.ammo_reserve])

	# Switch back to AK20. AK20 ammo was 23 before SG-8 swap (28 after the two
	# body/head shots, then -5 from the lethal loop above). Per-weapon state
	# should restore that value, NOT a fresh mag.
	var ak20_ammo_before_swap: int = 23
	player.equip_slot(0)
	if player.weapon_def != AK20:
		_fail("equip_slot(0) did not switch back to AK20")
		return
	if player.ammo_in_mag != ak20_ammo_before_swap:
		_fail("after switching back, AK20 ammo expected %d, got %d" % [ak20_ammo_before_swap, player.ammo_in_mag])
		return
	print("  [ok] equip_slot(0): AK20 ammo restored to %d (per-weapon ammo state works)" % player.ammo_in_mag)


func _aim_at(player: Node, world_target: Vector3) -> void:
	# Funnel through set_aim() so the camera-kick system (which composes aim
	# every physics frame) doesn't clobber the rotations we just wrote.
	var camera_pos: Vector3 = player.camera.global_position if player.camera != null else player.global_position + Vector3(0, 1.0, 0)
	var to: Vector3 = world_target - camera_pos
	var horiz_dist: float = Vector2(to.x, to.z).length()
	player.set_aim(atan2(to.x, to.z) + PI, atan2(to.y, horiz_dist))


func _fail(msg: String) -> void:
	push_error("[FAIL] " + msg)
	print("  [FAIL] %s" % msg)
	failed += 1
