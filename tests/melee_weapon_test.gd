extends SceneTree
## Unit test for equipped MELEE weapons (dagger 匕首 / hammer 锤子).
##
## Verifies the slot=="melee" fire path in try_fire():
##   1. equipping by id works and reports is_melee()
##   2. a swing deals the weapon's damage (body OR headshot multiple) to a
##      target inside melee_range
##   3. a swing consumes NO ammo (melee has no magazine)
##   4. the swing arms fire_interval_ms cooldown (no double-hit same frame)
##   5. a target beyond melee_range takes NO damage
##   6. the hammer hits harder than the dagger

const DAGGER := preload("res://shared/data/weapons/dagger.tres")
const HAMMER := preload("res://shared/data/weapons/hammer.tres")
const PLAYER_SCENE := preload("res://shared/scenes/player.tscn")

var failures: Array = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Attacker at origin (faces -Z by default), victim 1.5 m straight ahead.
	var attacker: Node = _spawn(2001, Vector3.ZERO)
	var victim: Node = _spawn(2002, Vector3(0, 0, -1.5))
	attacker.loadout = [DAGGER, HAMMER] as Array[Resource]
	# Let the hitbox Area3Ds register in the physics space.
	for i in range(4):
		await physics_frame

	# ── Dagger ────────────────────────────────────────────────────────────
	if not attacker.equip_by_id(&"dagger") or attacker.weapon_def.id != &"dagger":
		_fail("equip_by_id(dagger) failed")
	if not attacker.weapon_def.is_melee():
		_fail("dagger.is_melee() should be true")
	victim._invincible_until = 0.0
	var hp0: float = victim.hp
	var ammo0: int = attacker.ammo_in_mag
	attacker.try_fire()
	await physics_frame
	var dealt: float = hp0 - victim.hp
	if not _dmg_matches(dealt, DAGGER):
		_fail("dagger swing dealt %.1f, expected %.0f (body) or %.0f (head)" % [
			dealt, DAGGER.damage, DAGGER.damage * DAGGER.headshot_multiplier])
	if attacker.ammo_in_mag != ammo0:
		_fail("dagger consumed ammo (%d → %d) — melee must not" % [ammo0, attacker.ammo_in_mag])
	if attacker.time_until_next_shot <= 0.0:
		_fail("dagger swing didn't arm cooldown")

	# Immediate second swing is gated by cooldown → no damage.
	var hp_cd: float = victim.hp
	attacker.try_fire()
	await physics_frame
	if absf(victim.hp - hp_cd) > 0.01:
		_fail("dagger ignored cooldown — hit again same window")

	# ── Hammer ────────────────────────────────────────────────────────────
	victim._invincible_until = 0.0
	victim.hp = victim.max_hp
	attacker.time_until_next_shot = 0.0
	attacker.equip_by_id(&"hammer")
	var hp2: float = victim.hp
	attacker.try_fire()
	await physics_frame
	var dealt2: float = hp2 - victim.hp
	if not _dmg_matches(dealt2, HAMMER):
		_fail("hammer swing dealt %.1f, expected %.0f (body) or %.0f (head)" % [
			dealt2, HAMMER.damage, HAMMER.damage * HAMMER.headshot_multiplier])
	if dealt2 <= dealt:
		_fail("hammer (%.1f) should hit harder than dagger (%.1f)" % [dealt2, dealt])

	# ── Out of range ──────────────────────────────────────────────────────
	victim._invincible_until = 0.0
	victim.hp = victim.max_hp
	attacker.time_until_next_shot = 0.0
	victim.global_position = Vector3(0, 0, -(HAMMER.melee_range + 1.5))
	for i in range(3):
		await physics_frame
	var hp3: float = victim.hp
	attacker.try_fire()
	await physics_frame
	if absf(victim.hp - hp3) > 0.01:
		_fail("hammer hit a target beyond melee_range (%.1f m)" % HAMMER.melee_range)

	if failures.is_empty():
		print("  PASS — melee weapons: dagger %.0f / hammer %.0f dmg, no ammo, cooldown + range gated" % [
			DAGGER.damage, HAMMER.damage])
		quit(0)
	else:
		for f in failures:
			print("  FAIL: %s" % f)
		quit(1)


func _dmg_matches(dealt: float, weapon: Resource) -> bool:
	# A swing lands on the head or body hitbox depending on exact ray height;
	# accept either the base or the headshot-multiplied value.
	return absf(dealt - weapon.damage) < 0.5 \
		or absf(dealt - weapon.damage * weapon.headshot_multiplier) < 0.5


func _spawn(peer_id: int, at: Vector3) -> Node:
	var p: Node = PLAYER_SCENE.instantiate()
	p.set_multiplayer_authority(peer_id)
	p.is_local = false
	root.add_child(p)
	p.global_position = at
	# Enable hit detection like game_controller does on spawn.
	p.head_hitbox.monitoring = true
	p.body_hitbox.monitoring = true
	return p


func _fail(msg: String) -> void:
	failures.append(msg)
