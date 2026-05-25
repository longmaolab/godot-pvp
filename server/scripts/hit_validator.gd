extends Node
## Server-side hit validation with lag compensation.
##
## ★ Core security improvement over original /Users/longmao/projects/pvp-game/server.js
##   line 834, which trusted client-reported damage. Here the server holds the
##   only authoritative ray.
##
## Algorithm per fire op (tick T):
##   1. Look up shooter's eye position at server tick T (from MatchAuthority history).
##   2. Rewind every potential target's position by ceil(client_ping_ms / TICK_MS / 2)
##      ticks — this lets us hit-test against where targets *appeared to be* on the
##      shooter's screen at the moment they pressed fire.
##   3. PhysicsServer3D.intersect_ray from eye along look direction (or pellets
##      with spread for shotguns).
##   4. Discriminate head vs body by colliding Area3D name:
##        "head_hitbox" → headshot
##        "body_hitbox" → body
##      Player.tscn must use these exact names.
##   5. Compute final damage:
##        base = weapon_def.damage * (1 + upgrades.damage_lvl * 0.12)
##        if headshot:
##          if weapon_def.instakill_headshot: dmg = target.hp
##          else: dmg *= weapon_def.headshot_multiplier
##   6. Apply via MatchAuthority.apply_damage(target, dmg, shooter_id, weapon_id).
##
## All operations are server-only — clients never invoke these RPCs.

const TICK_DELTA_MS := 1000.0 / 30.0
const MAX_PING_COMPENSATION_MS := 200.0   # cap on rewind to stop egregious abuse


# Called by MatchAuthority during tick processing.
# `shooter_history`: Array of {tick, pos, yaw, pitch} ring buffer slots.
# `targets_history`: Dictionary[peer_id → Array of same].
# Returns Array of {target, damage, headshot} hit records to apply.
## NOTE: weapon_def is intentionally typed as Resource (not WeaponDef) so this
## script can be loaded standalone without the class_name cache. At runtime the
## fields accessed (damage, pellets, spread, headshot_multiplier, etc.) match
## WeaponDef's @export vars.
func resolve_fire(
	weapon_def: Resource,
	shooter_id: int,
	shooter_collider_rids: Array,
	shooter_eye_pos: Vector3,
	shooter_look_dir: Vector3,
	shooter_upgrades: Dictionary,
	client_ping_ms: float,
	world_space: PhysicsDirectSpaceState3D,
	target_lookup_by_collider: Dictionary,
) -> Array:
	var results: Array = []
	if weapon_def == null:
		return results

	# TODO: rewind target positions by min(client_ping_ms / 2, cap). Requires
	# read access to MatchAuthority._position_history. M1 implementation will
	# inject the history accessor at construction time.

	var pellets: int = maxi(1, weapon_def.pellets)
	for _i in range(pellets):
		var dir: Vector3 = _apply_spread(shooter_look_dir, weapon_def.spread)
		var max_dist: float = 500.0 if weapon_def.is_hitscan() else 200.0
		var query := PhysicsRayQueryParameters3D.create(
			shooter_eye_pos, shooter_eye_pos + dir * max_dist
		)
		# exclude expects Array[RID] of shooter's own collision shapes/bodies.
		var exclude_rids: Array[RID] = []
		for r in shooter_collider_rids:
			exclude_rids.append(r)
		query.exclude = exclude_rids

		var hit: Dictionary = world_space.intersect_ray(query)
		if hit.is_empty():
			continue

		var collider: Node = hit.collider
		var target_peer: int = target_lookup_by_collider.get(collider, 0)
		if target_peer == 0 or target_peer == shooter_id:
			continue

		var is_headshot: bool = collider.name == &"head_hitbox"
		var dmg: float = _compute_damage(weapon_def, is_headshot, shooter_upgrades)
		results.append({
			"target": target_peer,
			"damage": dmg,
			"headshot": is_headshot,
		})
	return results


func _compute_damage(weapon_def: Resource, is_headshot: bool, upgrades: Dictionary) -> float:
	# Upgrade tiers (UPGRADE_STATS in /Users/longmao/projects/pvp-game/server.js):
	#   damage_lvl 1/2/3 → +12% / +24% / +36%
	var dmg_lvl: int = upgrades.get(&"damage", 0)
	var dmg: float = weapon_def.damage * (1.0 + 0.12 * float(dmg_lvl))
	if is_headshot:
		# instakill flag overrides multiplier (replaces INSTAKILL_HS_WEAPONS set).
		if weapon_def.instakill_headshot:
			return 999_999.0   # caller clamps to target.hp
		dmg *= weapon_def.headshot_multiplier
	return dmg


func _apply_spread(dir: Vector3, spread: float) -> Vector3:
	if spread <= 0.0:
		return dir.normalized()
	# Cone sample: pick a random angle around the look axis.
	var yaw := randf_range(-spread, spread)
	var pitch := randf_range(-spread, spread)
	var look_basis := Basis.looking_at(dir)
	return (look_basis * Vector3(yaw, pitch, -1.0)).normalized()
