extends Node3D
## Server-only ballistic projectile for throwable weapons (grenades etc).
## Spawned by FireResolver when the fired weapon has is_throwable=true.
## Lives in the shooter's RoomWorld (or main tree for practice), integrates
## position each physics frame with gravity, detects contact via raycast,
## and detonates either on contact OR after the weapon's fuse_seconds —
## whichever comes first. Detonation applies AoE damage with linear
## distance falloff to every player inside `explode_radius`.
##
## Visuals: a thin tracer + explosion VFX are added in a follow-up pass.
## For MVP the projectile is invisible; the explosion damage + feed line
## are the player-visible effect.

const GRAVITY := 9.8
const SUBSTEP := 0.05   # 20 Hz simulation; aligns with snapshot cadence
const _SHOOT_MASK_SERVER: int = (1 << 0) | (1 << 2)

var weapon: Resource = null       # WeaponDef — read explode_damage, explode_radius, fuse_seconds
var shooter: Node = null          # the player who threw it (excluded from collision + as the damage attribution)
var velocity: Vector3 = Vector3.ZERO
var elapsed: float = 0.0
var detonated: bool = false
# Monotonic counter so spawn / explode RPCs can be paired on the client. -1
# means "not broadcast yet"; set by FireResolver right after spawn so the
# value is stable across the throw's lifetime.
static var _next_id: int = 1
var proj_id: int = -1


func _physics_process(delta: float) -> void:
	if detonated:
		return
	# Integrate in fixed substeps so a slow framerate doesn't tunnel the
	# projectile through walls.
	var remaining: float = delta
	while remaining > 0.0 and not detonated:
		var step: float = minf(remaining, SUBSTEP)
		remaining -= step
		_integrate_step(step)


func _integrate_step(step: float) -> void:
	elapsed += step
	# Fuse check FIRST so a 0-fuse "impact grenade" (fuse_seconds=0) still
	# explodes on contact below — _explode is idempotent so an immediate
	# fuse + contact in the same step doesn't double-fire.
	if weapon.fuse_seconds > 0.0 and elapsed >= weapon.fuse_seconds:
		_explode()
		return
	# Apply gravity then translate. Use a raycast from old → new position
	# to catch fast projectiles that would otherwise skip over walls.
	velocity.y -= GRAVITY * step
	var prev: Vector3 = global_position
	var next: Vector3 = prev + velocity * step
	var space: PhysicsDirectSpaceState3D = _resolve_space()
	if space != null:
		var query := PhysicsRayQueryParameters3D.create(prev, next)
		query.collision_mask = _SHOOT_MASK_SERVER
		query.collide_with_areas = false   # skip hitboxes; we want world surfaces
		query.collide_with_bodies = true
		if shooter != null and is_instance_valid(shooter):
			query.exclude = [shooter.get_rid()]
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			global_position = hit.position
			_explode()
			return
	global_position = next


func _resolve_space() -> PhysicsDirectSpaceState3D:
	# Match fire_resolver: use the shooter's World3D (= RoomWorld viewport
	# in MP) so the raycast finds room-local geometry.
	var world: World3D = null
	if shooter != null and is_instance_valid(shooter):
		world = shooter.get_world_3d()
	if world == null:
		world = get_world_3d()
	if world == null:
		return null
	return world.direct_space_state


func _explode() -> void:
	if detonated:
		return
	detonated = true
	var center: Vector3 = global_position
	var radius: float = weapon.explode_radius
	var max_dmg: float = weapon.explode_damage
	var net_rpc: Node = get_tree().root.get_node_or_null(^"NetRpc")
	# Broadcast explosion so every client can spawn VFX + free their proxy.
	if net_rpc != null and proj_id > 0:
		net_rpc.server_throwable_explode.rpc(proj_id, center)
	# Find every player in radius and apply damage with linear falloff.
	# Player lookup via the game_controller's players_by_peer (queried
	# by walking up the tree to find /root/Game).
	var game: Node = get_tree().root.get_node_or_null(^"Game")
	if game == null or not "players_by_peer" in game:
		queue_free()
		return
	for peer in game.players_by_peer.keys():
		var victim: Node = game.players_by_peer[peer]
		if victim == null or not is_instance_valid(victim):
			continue
		if "is_dead" in victim and victim.is_dead:
			continue
		var dist: float = victim.global_position.distance_to(center)
		if dist > radius:
			continue
		var falloff: float = clampf(1.0 - dist / radius, 0.0, 1.0)
		var dmg: float = max_dmg * falloff
		if dmg < 1.0:
			continue
		if victim.has_method(&"apply_damage"):
			victim.apply_damage(dmg, shooter)
		# Broadcast feed line via existing damage broadcast so each client
		# sees the AoE outcome and updates HP locally.
		if net_rpc != null and "server_apply_damage" in net_rpc:
			var victim_peer: int = victim.get_multiplayer_authority()
			var src_peer: int = shooter.get_multiplayer_authority() if shooter != null and is_instance_valid(shooter) else 0
			net_rpc.server_apply_damage.rpc(victim_peer, victim.hp, src_peer,
				weapon.id if weapon != null else &"throwable", false)
	queue_free()
