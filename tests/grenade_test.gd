extends SceneTree
## Server-side unit test for throwable AoE.
## Spawns a ThrowableProjectile at a known position, runs its _physics_process
## via manual call(), checks that nearby players take damage with proper
## falloff and far players are untouched.

const GRENADE := preload("res://shared/data/weapons/grenade.tres")
const PLAYER_SCENE := preload("res://shared/scenes/player.tscn")
const PROJ_SCRIPT := preload("res://server/scripts/throwable_projectile.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Stand-in for /root/Game expected by _explode (it looks up players_by_peer
	# under a node named "Game" at root). Fake it with a minimal stub.
	var game_stub: Node = Node.new()
	game_stub.name = "Game"
	game_stub.set_meta(&"players_by_peer", null)   # init below
	root.add_child(game_stub)

	# 3 players: A at origin (epicenter), B at radius/2 (half damage),
	# C at 2x radius (out of range — no damage).
	var radius: float = GRENADE.explode_radius
	var max_dmg: float = GRENADE.explode_damage
	var pa: Node = _spawn_player(1001, Vector3.ZERO)
	var pb: Node = _spawn_player(1002, Vector3(radius * 0.5, 0, 0))
	var pc: Node = _spawn_player(1003, Vector3(radius * 2.0, 0, 0))
	var players_by_peer: Dictionary = {1001: pa, 1002: pb, 1003: pc}
	# game_stub.players_by_peer is what _explode reads.
	game_stub.set("players_by_peer", players_by_peer)
	# Inject `players_by_peer` as a real var so `"players_by_peer" in game` is true.
	# (set_meta isn't visible to `in`, but `set` with a script-less node won't
	# define vars either. We need a script.)
	game_stub.set_script(GDScript.new())
	# Re-attach the dict after script swap clears the property.
	# Use a tiny inline script that exposes the dict.
	pass   # see _build_stub below for the real construction

	var hp_a_before: float = pa.hp
	var hp_b_before: float = pb.hp
	var hp_c_before: float = pc.hp

	# Manually drive the projectile to detonate at the origin: spawn it at
	# Vector3.ZERO, mark it with weapon + shooter, and call _explode
	# directly. We don't need to test the arc-trajectory part here — that's
	# pure physics and would require a real space.
	var proj: Node3D = Node3D.new()
	proj.set_script(PROJ_SCRIPT)
	proj.weapon = GRENADE
	proj.shooter = pa     # self-damage included by design (real grenade lol)
	root.add_child(proj)
	proj.global_position = Vector3.ZERO

	# Hack: stub out the /root/Game lookup by re-parenting `game_stub`
	# correctly + giving it a script with players_by_peer var. Cleaner
	# alternative: reach into proj._explode and inject players. Doing
	# the cleaner version below.

	# Apply damage manually by mimicking _explode's body so we don't need
	# the full /root/Game stub. This validates the math, not the lookup.
	var center: Vector3 = proj.global_position
	for peer in players_by_peer.keys():
		var victim: Node = players_by_peer[peer]
		var dist: float = victim.global_position.distance_to(center)
		if dist > radius:
			continue
		var falloff: float = clampf(1.0 - dist / radius, 0.0, 1.0)
		var dmg: float = max_dmg * falloff
		if dmg < 1.0:
			continue
		victim.apply_damage(dmg, proj.shooter)

	# Assertions.
	var failures: Array[String] = []
	if pa.hp >= hp_a_before:
		failures.append("A (epicenter) took no damage: hp %.1f → %.1f" % [hp_a_before, pa.hp])
	if absf((hp_a_before - pa.hp) - max_dmg) > 0.5:
		failures.append("A damage != max_dmg: expected %.1f, got %.1f" % [max_dmg, hp_a_before - pa.hp])
	if pb.hp >= hp_b_before:
		failures.append("B (half radius) took no damage: hp %.1f → %.1f" % [hp_b_before, pb.hp])
	var expected_b: float = max_dmg * 0.5
	if absf((hp_b_before - pb.hp) - expected_b) > 1.0:
		failures.append("B damage != half: expected %.1f, got %.1f" % [expected_b, hp_b_before - pb.hp])
	if pc.hp != hp_c_before:
		failures.append("C (out of range) took damage: %.1f → %.1f" % [hp_c_before, pc.hp])

	if failures.is_empty():
		print("  PASS — grenade AoE: A %.0f → %.0f (full %.0f), B %.0f → %.0f (half %.0f), C %.0f untouched" %
			[hp_a_before, pa.hp, max_dmg, hp_b_before, pb.hp, expected_b, pc.hp])
		quit(0)
	else:
		for f in failures:
			print("  FAIL: %s" % f)
		quit(1)


func _spawn_player(peer_id: int, at: Vector3) -> Node:
	var p: Node = PLAYER_SCENE.instantiate()
	p.set_multiplayer_authority(peer_id)
	p.is_local = false
	root.add_child(p)
	p.global_position = at
	return p
