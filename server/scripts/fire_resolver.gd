extends RefCounted
## Server-authoritative fire resolution. Extracted from GameController to keep
## that file under the 1000-line target.
##
## One entrypoint — `resolve_fire(host, peer_id, weapon_id, fire_yaw, fire_pitch)`
## — runs the full 6-phase pipeline:
##   1. gate (peer/dead/reload/cooldown/ammo)
##   2. weapon resolve + loadout check
##   3. snap-aim cheat check (R2: works on listen-host + DS baselines)
##   4. commit ammo + cooldown
##   5. lag-comp rewind + raycast + restore
##   6. hit resolution + apply_damage + broadcast
##
## `host` is the GameController node — we read its players_by_peer,
## lag_comp, is_dedicated_server, lag_compensation_enabled,
## default_lag_comp_ping_ms and _resolve_weapon() helper.
##
## Reference via `const FireResolver = preload(...)` (not class_name) so
## headless tests work without the editor's class registry.

const _SHOOT_MASK_SERVER: int = (1 << 0) | (1 << 2)


## Resolves a fire intent from the given peer using the host's own view of the
## world. Only the host runs this; result is broadcast via server_apply_damage.
## DS-M4 fix: the shooter's instantaneous yaw/pitch are sent with the fire RPC,
## so the server raycasts at the EXACT direction the client was looking instead
## of using its interp-delayed view of the shooter's transform.
# Deviate `d` by a random direction within a cone of half-angle `half`
# (radians). sqrt(randf()) gives a roughly uniform disc so shots cluster
# toward the center rather than the rim.
static func _apply_cone(d: Vector3, half: float) -> Vector3:
	if half <= 0.0:
		return d
	var ang: float = randf() * TAU
	var rad: float = sqrt(randf()) * half
	var up: Vector3 = Vector3.UP if absf(d.y) < 0.99 else Vector3.RIGHT
	var right: Vector3 = d.cross(up).normalized()
	var realup: Vector3 = right.cross(d).normalized()
	var offset: Vector3 = (right * cos(ang) + realup * sin(ang)) * tan(rad)
	return (d + offset).normalized()


static func resolve_fire(host: Node, peer_id: int, weapon_id: StringName, fire_yaw: float, fire_pitch: float) -> void:
	if not host.multiplayer.is_server():
		return
	var is_dedicated_server: bool = host.is_dedicated_server
	if is_dedicated_server:
		print("[server] fire peer=%d weapon=%s aim=(%.3f,%.3f)" % [peer_id, weapon_id, fire_yaw, fire_pitch])
	var shooter: Node = host.players_by_peer.get(peer_id)
	if shooter == null:
		if is_dedicated_server:
			print("[server]   ↳ ignored: shooter not in players_by_peer (keys=%s)" % str(host.players_by_peer.keys()))
		return
	if shooter.is_dead:
		if is_dedicated_server:
			print("[server]   ↳ ignored: shooter is dead")
		return
	# C3: server-authoritative gate. Run BEFORE any state mutation so this
	# handler enforces ammo / cooldown / reload regardless of whether the
	# RPC came via try_fire (legit input bit) or a direct client_fire spam.
	if shooter.is_reloading:
		if is_dedicated_server:
			print("[server]   ↳ ignored: shooter is reloading")
		return
	if shooter.time_until_next_shot > 0.0:
		if is_dedicated_server:
			print("[server]   ↳ ignored: cooldown %.3fs remaining" % shooter.time_until_next_shot)
		return
	if shooter.ammo_in_mag <= 0:
		# Auto-reload on empty mag — matches try_fire() line 712. Without this,
		# direct client_fire RPCs (which skip try_fire's reload trigger) leave
		# the server's ammo pinned at 0 forever, and the player can't shoot
		# again even though they're holding the trigger. User-reported bug:
		# "子弹打完之后没有自动装弹，不能继续玩".
		if not shooter.is_reloading:
			shooter.start_reload()
		if is_dedicated_server:
			print("[server]   ↳ ignored: empty mag → auto-reload triggered")
		return
	var weapon: Resource = host._resolve_weapon(weapon_id)
	if weapon == null:
		push_warning("[server] unknown weapon_id: %s" % weapon_id)
		return
	# C3: shooter must actually own this weapon. Otherwise a peer can pass
	# &"railgun" while equipped with an AK and get railgun damage every shot.
	var weapon_in_loadout: bool = false
	for w in shooter.loadout:
		if w != null and StringName(w.id) == weapon_id:
			weapon_in_loadout = true
			break
	if not weapon_in_loadout:
		if is_dedicated_server:
			print("[server]   ↳ ignored: weapon %s not in shooter's loadout" % weapon_id)
		return
	# P1-8: fire-time weapon must equal server's tracked current weapon.
	# Without this, the loadout check above is the only gate — a client
	# could fire as any-loadout-weapon at any time (e.g. fire as railgun
	# while equipped with AK20 → take railgun damage with AK fire rate).
	# Skip the check on the very first fire when the server's mirror is
	# still on its spawn weapon and the client hasn't sent a switch yet.
	if shooter.weapon_def != null and StringName(shooter.weapon_def.id) != weapon_id:
		if is_dedicated_server:
			print("[server]   ↳ ignored: fire weapon=%s but shooter currently holds %s" % [weapon_id, shooter.weapon_def.id])
		return
	# C4: clamp aim against the shooter's last validated input frame. A real
	# human can't snap-aim more than ~PI per fire interval, so anything past
	# MAX_AIM_DELTA_RAD almost certainly came from a teleport-aim cheat.
	# Skip on first fire (no baseline yet) and when aim wasn't provided.
	if fire_yaw != INF and fire_pitch != INF:
		if not (is_finite(fire_yaw) and is_finite(fire_pitch)):
			if is_dedicated_server:
				print("[server]   ↳ ignored: non-finite aim")
			return
		# R2: pick the correct aim baseline for this peer's connection mode.
		# DS path → server replays inputs into _remote_input_yaw/pitch.
		# Listen-host path → use_remote_input=false; instead the remote
		# client's last `_net_apply_state` RPC populates _net_remote_yaw/pitch.
		# P2-20: first-shot fallback. If neither baseline is set yet (a fresh
		# spawn fires before its first input/state arrives) use the shooter's
		# current rotation as the baseline. Without this, the C4 check was
		# entirely skipped on the very first shot, giving a one-tick window
		# for snap-aim cheats on the opening engagement of every life.
		var have_baseline: bool = false
		var baseline_yaw: float = 0.0
		var baseline_pitch: float = 0.0
		if shooter.use_remote_input and shooter._remote_input_tick >= 0:
			have_baseline = true
			baseline_yaw = shooter._remote_input_yaw
			baseline_pitch = shooter._remote_input_pitch
		elif "_net_has_remote_target" in shooter and shooter._net_has_remote_target:
			have_baseline = true
			baseline_yaw = shooter._net_remote_yaw
			baseline_pitch = shooter._net_remote_pitch
		else:
			# Server's last-known transform — usually the spawn pose. Means
			# even a never-moved fresh client can't fire at an absurd aim
			# delta from "what they spawned facing".
			have_baseline = true
			baseline_yaw = shooter.rotation.y
			baseline_pitch = shooter.head.rotation.x if shooter.has_node(^"Head") else 0.0
		if have_baseline:
			var dy: float = absf(wrapf(fire_yaw - baseline_yaw, -PI, PI))
			var dp: float = absf(fire_pitch - baseline_pitch)
			if dy > NetProtocol.MAX_AIM_DELTA_RAD or dp > NetProtocol.MAX_AIM_DELTA_RAD:
				if is_dedicated_server:
					print("[server]   ↳ ignored: aim delta yaw=%.2f pitch=%.2f exceeds %.2f" % [dy, dp, NetProtocol.MAX_AIM_DELTA_RAD])
				return
	# C3 commit: decrement ammo + arm cooldown HERE (try_fire defers these on
	# server-authoritative paths so we have a single source of truth).
	shooter.ammo_in_mag -= 1
	shooter.time_until_next_shot = weapon.fire_interval_seconds()
	shooter.ammo_changed.emit(shooter.ammo_in_mag, shooter.ammo_reserve)
	# Throwable branch: spawn a server-simulated projectile and let it handle
	# its own arc + contact + fuse + AoE damage. Bypasses the hitscan ray
	# below entirely.
	if "is_throwable" in weapon and weapon.is_throwable:
		_spawn_throwable(host, shooter, weapon, fire_yaw, fire_pitch)
		return
	# If the client sent aim, snap the shooter's body/head to that direction
	# BEFORE the raycast so the ray comes out of the camera in the right line.
	# We restore the interpolated state in the saved_positions loop below.
	var saved_shooter_aim: Dictionary = {}
	if fire_yaw != INF and fire_pitch != INF and shooter.has_node(^"Head"):
		saved_shooter_aim = {
			"yaw":   shooter.rotation.y,
			"pitch": shooter.head.rotation.x,
		}
		shooter.rotation.y = fire_yaw
		shooter.head.rotation.x = clampf(fire_pitch, -PI * 0.49, PI * 0.49)

	# ── Lag compensation: temporarily rewind every other player to where they
	# were on the shooter's screen when they pulled the trigger. The shooter
	# saw targets at (now - interp_delay - ping/2). Without rewinding the full
	# amount, the server's raycast hits where targets ARE, not where the
	# shooter SAW them, and shots feel "should have hit" but don't register. ──
	var saved_positions: Dictionary = {}
	if host.lag_compensation_enabled and host.lag_comp != null:
		var rewind_ms: float = float(NetProtocol.SNAPSHOT_INTERPOLATION_MS) + host.default_lag_comp_ping_ms * 0.5
		var rewind_to_ms: float = float(Time.get_ticks_msec()) - rewind_ms
		# F3-M4: only rewind peers in the SAME room as the shooter. Peers
		# in other concurrent matches are physically in a different World3D
		# anyway (the raycast can't hit them) — rewinding them would just
		# waste CPU + create weird transient state for those rooms' own
		# fire RPCs that fire the same tick.
		var shooter_room: String = host._room_id_for_peer(peer_id)
		for tp in host.players_by_peer.keys():
			if tp == peer_id:
				continue
			if not shooter_room.is_empty() and host._room_id_for_peer(tp) != shooter_room:
				continue
			var pnode: Node = host.players_by_peer[tp]
			if pnode == null or not is_instance_valid(pnode):
				continue
			var sample = host.lag_comp.sample_at(tp, rewind_to_ms)
			if sample == null:
				continue
			saved_positions[tp] = {"pos": pnode.global_position, "yaw": pnode.rotation.y, "pitch": pnode.head.rotation.x}
			pnode.global_position = sample.pos
			pnode.rotation.y = sample.yaw
			pnode.head.rotation.x = sample.pitch
			# Codex 12:39 P1: PhysicsServer3D doesn't auto-resync Area3D
			# broadphase entries when their global_position is written from
			# script; same-tick raycasts will see the OLD hitbox AABB. Push
			# the new transform for the target's body AND both hitbox areas
			# so intersect_ray below sees the rewound silhouette.
			PhysicsServer3D.body_set_state(pnode.get_rid(),
				PhysicsServer3D.BODY_STATE_TRANSFORM, pnode.global_transform)
			if "head_hitbox" in pnode and pnode.head_hitbox != null:
				PhysicsServer3D.area_set_transform(pnode.head_hitbox.get_rid(),
					pnode.head_hitbox.global_transform)
			if "body_hitbox" in pnode and pnode.body_hitbox != null:
				PhysicsServer3D.area_set_transform(pnode.body_hitbox.get_rid(),
					pnode.body_hitbox.global_transform)
		# Shooter's own physics state (kept for the aim-spoof a few lines up).
		PhysicsServer3D.body_set_state(shooter.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, shooter.global_transform)

	var origin: Vector3 = shooter.camera.global_position
	var dir: Vector3 = -shooter.camera.global_transform.basis.z
	# ── Accuracy cone (server-authoritative spread) ───────────────────────
	# Every shot deviates randomly within a cone whose size depends on the
	# shooter's state: tight when crouched / ADS, wide while running. The
	# server rolls it, so this is the truth — the client's crosshair is no
	# longer a guarantee of a hit (intended: that's what spread means).
	var cone: float = weapon.accuracy_cone if "accuracy_cone" in weapon else 0.0
	if cone > 0.0:
		var ads: bool = bool(shooter.get("_is_ads"))
		var crouched: bool = bool(shooter.get("_is_crouching"))
		var horiz_speed: float = Vector2(shooter.velocity.x, shooter.velocity.z).length()
		if ads:
			cone *= (weapon.spread_ads_mult if "spread_ads_mult" in weapon else 0.18)
		elif crouched:
			cone *= (weapon.spread_crouch_mult if "spread_crouch_mult" in weapon else 0.55)
		if horiz_speed > 2.0 and not ads:
			cone *= (weapon.spread_moving_mult if "spread_moving_mult" in weapon else 2.6)
		dir = _apply_cone(dir, cone)
	var max_dist: float = 500.0 if weapon.is_hitscan() else 200.0
	# F3-M4: use the SHOOTER's World3D (= the room's SubViewport own world
	# after F3-M3b) rather than the main scene's. Without this, raycasts
	# in room A would query the default world's physics space and never
	# intersect colliders that live under a per-room SubViewport.
	# Falls back to host's world for shooters that haven't been reparented
	# (e.g. practice / pre-room peers).
	var shooter_world: World3D = shooter.get_world_3d()
	if shooter_world == null:
		shooter_world = host.get_world_3d()
	var space: PhysicsDirectSpaceState3D = shooter_world.direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * max_dist)
	query.collision_mask = _SHOOT_MASK_SERVER
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var ex: Array[RID] = [shooter.get_rid(), shooter.head_hitbox.get_rid(), shooter.body_hitbox.get_rid()]
	query.exclude = ex

	var hit: Dictionary = space.intersect_ray(query)
	if is_dedicated_server:
		if hit.is_empty():
			print("[server]   ↳ ray from=%s dir=%s MISSED" % [str(origin.snapped(Vector3(0.01,0.01,0.01))), str(dir.snapped(Vector3(0.001,0.001,0.001)))])
		else:
			print("[server]   ↳ ray hit %s (%s)" % [hit.collider.name, hit.collider.get_class()])

	# Restore rewound players regardless of hit/miss. Also re-push physics
	# transforms so other systems (collisions, area enter/exit, the very
	# next raycast on a different fire RPC the same tick) see the present
	# position rather than the lingering rewound one.
	for tp in saved_positions.keys():
		var pnode2: Node = host.players_by_peer.get(tp)
		if pnode2 == null or not is_instance_valid(pnode2):
			continue
		var saved: Dictionary = saved_positions[tp]
		pnode2.global_position = saved["pos"]
		pnode2.rotation.y = saved["yaw"]
		pnode2.head.rotation.x = saved["pitch"]
		PhysicsServer3D.body_set_state(pnode2.get_rid(),
			PhysicsServer3D.BODY_STATE_TRANSFORM, pnode2.global_transform)
		if "head_hitbox" in pnode2 and pnode2.head_hitbox != null:
			PhysicsServer3D.area_set_transform(pnode2.head_hitbox.get_rid(),
				pnode2.head_hitbox.global_transform)
		if "body_hitbox" in pnode2 and pnode2.body_hitbox != null:
			PhysicsServer3D.area_set_transform(pnode2.body_hitbox.get_rid(),
				pnode2.body_hitbox.global_transform)
	# Restore the shooter's pre-fire aim too — we only spoofed it for the ray.
	if not saved_shooter_aim.is_empty():
		shooter.rotation.y = saved_shooter_aim["yaw"]
		shooter.head.rotation.x = saved_shooter_aim["pitch"]

	if hit.is_empty():
		return
	var collider: Node = hit.collider
	if collider == null:
		return
	# Hitbox path: every damageable thing tags its hitboxes with owner_player.
	# That can be a PlayerController (broadcast HP via server_apply_damage) or
	# a DummyTarget (server-only state, take_hit signal observed locally).
	if collider.has_meta(&"owner_player"):
		var victim: Node = collider.get_meta(&"owner_player")
		if victim == null or not is_instance_valid(victim):
			return
		var is_head: bool = collider.get_meta(&"is_head", false)
		if victim is PlayerController:
			if victim.is_dead:
				return
			var dmg: float = PlayerController._compute_damage(weapon, is_head)
			# Apply buff + powershot damage multipliers from the SERVER's view
			# of the shooter. The mirror is kept in sync via client_use_ability
			# (listen-host) or the INPUT_ABILITY edge (DS). Skipping these in
			# MP would mean the kid sees the "Focus Fire active" indicator but
			# does plain-vanilla damage.
			var now_s: float = Time.get_ticks_msec() / 1000.0
			if shooter._buff_def != null and now_s < shooter._buff_active_until:
				dmg *= shooter._buff_def.damage_mult
			if shooter._powershot_armed != null:
				dmg *= shooter._powershot_armed.damage_mult
				shooter.ability_consumed.emit(shooter._powershot_armed)
				shooter._powershot_armed = null
			var victim_peer: int = victim.get_multiplayer_authority()
			var hp_before: float = victim.hp
			victim.apply_damage(dmg, shooter)
			# test.md Bug B: read AUTHORITATIVE post-damage HP rather than the
			# pre-computed `victim.hp - dmg`. If apply_damage rejected the hit
			# (typically the 2.5s post-respawn i-frame, or victim_is_dead from a
			# concurrent kill shot), HP is unchanged. Broadcasting the fake
			# reduction would let every client decrement HP and potentially
			# fake a death animation for a still-alive victim.
			var new_hp: float = victim.hp
			if new_hp == hp_before:
				if is_dedicated_server:
					print("[server]   ↳ absorbed: victim %d in i-frame or dead" % victim_peer)
				# R9: shot landed but did 0 damage (victim in 2.5s respawn
				# i-frame, or already-dead). The fire-interval cooldown we
				# armed in stage 4 above doesn't earn its keep when the shot
				# accomplished nothing — refund it so the next fire RPC isn't
				# gated by a "you wasted a shot" penalty. Caveat: this only
				# resets the SERVER-side counter. The remote client's local
				# time_until_next_shot was armed by its own try_fire() and
				# ticks independently; a fully-refunded UX needs a broadcast
				# RPC (revisit when hit feedback gets a general polish pass).
				shooter.time_until_next_shot = 0.0
				return
			if is_dedicated_server:
				print("[server] hit: shooter=%d victim=%d dmg=%.1f head=%s new_hp=%.1f hitbox=%s" % [peer_id, victim_peer, dmg, is_head, new_hp, collider.name])
			# Anti-cheat: feed kill / headshot counters into ProfileService for
			# running ratio tracking. Only count fatal hits (new_hp <= 0) so a
			# bodyshot streak doesn't dilute the ratio. ProfileService warn-only.
			if new_hp <= 0.0:
				var ps: Node = host.get_tree().root.get_node_or_null(^"ProfileService")
				if ps != null:
					if is_head and ps.has_method(&"record_headshot_kill"):
						ps.record_headshot_kill(peer_id)
					elif not is_head and ps.has_method(&"record_body_kill"):
						ps.record_body_kill(peer_id)
			var net_rpc: Node = host.get_node_or_null(^"/root/NetRpc")
			if net_rpc != null:
				# F3-M3c: scope damage feedback to the victim's room so a
				# kid in room B doesn't see room A's HP bars dropping.
				var audience: Array = host._room_scoped_audience(victim_peer)
				if audience.is_empty():
					net_rpc.server_apply_damage.rpc(victim_peer, new_hp, peer_id, weapon_id, is_head)
				else:
					var live: Array = host.multiplayer.get_peers()
					for peer in audience:
						if peer in live:
							net_rpc.server_apply_damage.rpc_id(peer, victim_peer, new_hp, peer_id, weapon_id, is_head)
			# Death broadcast happens in _on_any_player_died now (R1 fix):
			# damage_zone / admin nuke / scripted test kills all funnel
			# through the `died` signal, so the broadcast belongs in the
			# central listener — not duplicated per damage source.
			return
		# Non-player damageable (e.g. DummyTarget). Use whichever entrypoint
		# the target exposes.
		if victim.has_method(&"take_hit"):
			victim.take_hit(weapon, is_head, shooter)
		elif victim.has_method(&"apply_damage"):
			var dmg2: float = PlayerController._compute_damage(weapon, is_head)
			victim.apply_damage(dmg2, shooter)
		return
	# Static collider with a direct take_hit (rare; defensive).
	if collider.has_method(&"take_hit"):
		var is_head_d: bool = collider.name == &"HeadHitbox" or collider.get_meta(&"is_head", false)
		collider.take_hit(weapon, is_head_d, shooter)
		return


## Throwable spawn — called by the is_throwable branch above. Builds the
## projectile node, gives it an initial velocity derived from aim + the
## weapon's throw_arc_pitch, parents it under the shooter's room (or game
## controller for practice), and lets its own _physics_process drive the
## arc + contact + fuse + AoE damage logic.
static func _spawn_throwable(host: Node, shooter: Node, weapon: Resource, fire_yaw: float, fire_pitch: float) -> void:
	var proj_script = load("res://server/scripts/throwable_projectile.gd")
	var proj: Node3D = Node3D.new()
	proj.set_script(proj_script)
	proj.weapon = weapon
	proj.shooter = shooter
	# Start at the shooter's camera so the throw feels first-person.
	var origin: Vector3 = shooter.camera.global_position if shooter.camera != null else shooter.global_position + Vector3(0, 1, 0)
	proj.global_position = origin
	# Derive throw direction from explicit aim if provided, else use the
	# shooter's transform basis.
	var yaw: float = fire_yaw if fire_yaw != INF else shooter.rotation.y
	var pitch: float = fire_pitch if fire_pitch != INF else (shooter.head.rotation.x if shooter.has_node(^"Head") else 0.0)
	# Add the weapon-specific arc lift so flat aim still produces a curve.
	pitch = clampf(pitch + weapon.throw_arc_pitch, -PI * 0.49, PI * 0.49)
	var dir: Vector3 = Vector3(
		-sin(yaw) * cos(pitch),
		sin(pitch),
		-cos(yaw) * cos(pitch)
	)
	var velocity: Vector3 = dir.normalized() * weapon.throw_speed
	proj.velocity = velocity
	# Allocate a monotonic id so the client can pair spawn / explode RPCs.
	# _next_id is a static var on the script, incremented atomically per spawn.
	proj.proj_id = proj_script._next_id
	proj_script._next_id += 1
	# Parent under the shooter's RoomWorld (MP) or game controller (practice)
	# so World3D lookup in _resolve_space() finds the right physics space.
	var room_world: Node = null
	if "_room_id_for_peer" in host:
		var rid: String = host._room_id_for_peer(shooter.get_multiplayer_authority())
		if not rid.is_empty() and host.room_worlds.has(rid):
			room_world = host.room_worlds[rid]
	if room_world != null:
		room_world.add_child(proj)
	else:
		host.add_child(proj)
	# Broadcast the spawn to all peers so each client integrates the same
	# trajectory locally for visuals. Reliable because a dropped spawn
	# leaves the client unaware of the projectile (an explode broadcast
	# alone wouldn't reconstruct flight visuals).
	var net_rpc: Node = host.get_tree().root.get_node_or_null(^"NetRpc")
	if net_rpc != null and host.multiplayer.is_server():
		net_rpc.server_throwable_spawn.rpc(proj.proj_id, weapon.id, origin, velocity)
