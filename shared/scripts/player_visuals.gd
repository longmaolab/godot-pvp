extends RefCounted
## Cosmetic spawn helpers for PlayerController. All stateless — extracted as
## static methods rather than a child Node since none of them need lifecycle.
##
## Reference via `const PlayerVisuals = preload(...)` from the call site — we
## intentionally do NOT use `class_name` because the global class registry only
## gets populated by the editor on import, so headless test boots can't see a
## brand-new class_name'd type until the editor's been run once.
##
## What lives here:
##   - muzzle flash (point light + emissive spark, ~80ms decay)
##   - wall impact (scuff decal + spark burst)
##   - traveling-bullet tracer (sphere head + fading streak)
##   - floating name tag (Label3D above remote players)
##
## What does NOT live here:
##   - state-coupled effects that need to read player vars at fire time —
##     keep those in PlayerController so they can see _powershot_armed / etc.
##   - the damage-number label spawned on a hit (that's GameController's
##     `_spawn_damage_label`, scoped to client-side feedback)
##
## All scene-graph adds go to `tree.root` so the visuals outlive the player
## (matters for the killshot case where the shooter dies before its tracer
## finishes flying).


## Brief bright flash at the muzzle: an OmniLight3D pulse + a small emissive
## sphere. Both auto-free after ~80ms. Color follows the weapon's bullet_color.
static func spawn_muzzle_flash(weapon: Resource, camera: Camera3D, tree: SceneTree) -> void:
	if weapon == null or camera == null:
		return
	var color: Color = weapon.bullet_color
	var flash_pos: Vector3 = camera.global_transform * Vector3(0.18, -0.14, -0.5)

	# Dynamic point light — short and bright, faded by tween.
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 6.0
	light.omni_range = 4.5
	light.omni_attenuation = 1.5
	tree.root.add_child(light)
	light.global_position = flash_pos
	var tl: Tween = light.create_tween()
	tl.tween_property(light, "light_energy", 0.0, 0.08)
	tl.tween_callback(light.queue_free)

	# Tiny visible spark sphere so even un-lit surroundings show the flash.
	var spark := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.08
	sm.height = 0.16
	spark.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 8.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark.material_override = mat
	tree.root.add_child(spark)
	spark.global_position = flash_pos
	var ts: Tween = spark.create_tween()
	ts.tween_property(mat, "emission_energy_multiplier", 0.0, 0.07)
	ts.tween_callback(spark.queue_free)


## A short black scuff + a small burst of glowing particles where a bullet
## hits the world. Only fires on non-player hits (we have tracer + hitmarker
## for player hits already).
static func spawn_wall_impact(tree: SceneTree, world_pos: Vector3, normal: Vector3) -> void:
	# Scuff mark — flattened sphere lying on the surface.
	var decal := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.05
	sm.height = 0.03
	decal.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.05, 0.05, 0.9)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	decal.material_override = mat
	tree.root.add_child(decal)
	decal.global_position = world_pos + normal * 0.01
	# Orient the flat disk so its Y axis points along the surface normal.
	if normal.length_squared() > 0.0:
		var up: Vector3 = normal.normalized()
		var fwd: Vector3 = up.cross(Vector3.UP)
		if fwd.length_squared() < 0.001:
			fwd = up.cross(Vector3.RIGHT)
		fwd = fwd.normalized()
		var right: Vector3 = up.cross(fwd).normalized()
		decal.global_transform.basis = Basis(right, up, fwd)
	var td: Tween = decal.create_tween()
	td.tween_interval(1.6)
	td.tween_property(mat, "albedo_color:a", 0.0, 0.6)
	td.tween_callback(decal.queue_free)

	# Spark burst — CPUParticles3D one-shot, 5 emissive particles.
	var sparks := CPUParticles3D.new()
	sparks.amount = 6
	sparks.lifetime = 0.45
	sparks.one_shot = true
	sparks.explosiveness = 1.0
	sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_POINT
	sparks.direction = normal
	sparks.spread = 60.0
	sparks.initial_velocity_min = 2.0
	sparks.initial_velocity_max = 6.0
	sparks.gravity = Vector3(0, -8.0, 0)
	sparks.scale_amount_min = 0.04
	sparks.scale_amount_max = 0.08
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(1.0, 0.85, 0.4)
	smat.emission_enabled = true
	smat.emission = Color(1.0, 0.7, 0.2)
	smat.emission_energy_multiplier = 5.0
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var spark_mesh := SphereMesh.new()
	spark_mesh.radius = 0.025
	spark_mesh.height = 0.05
	sparks.mesh = spark_mesh
	sparks.material_override = smat
	tree.root.add_child(sparks)
	sparks.global_position = world_pos
	# Auto-free after particles finish.
	var tp: Tween = sparks.create_tween()
	tp.tween_interval(sparks.lifetime + 0.1)
	tp.tween_callback(sparks.queue_free)


## Traveling-bullet tracer adapted from arena-shooter-3d/scripts/player.gd
## (line 635). A glowing sphere head flies from muzzle to impact over
## 0.05-0.25s (distance-scaled) with a thin streak fading behind it. This
## reads as a real projectile, not the static line v0.3 used to draw.
static func spawn_local_tracer(tree: SceneTree, camera: Camera3D, color: Color, hit_info: Dictionary) -> void:
	if camera == null:
		return
	var muzzle_world: Vector3 = camera.global_transform * Vector3(0.18, -0.16, -0.45)
	var end_pos: Vector3
	var hit_player: bool = false
	if hit_info.is_empty():
		end_pos = camera.global_position + (-camera.global_transform.basis.z) * 120.0
	else:
		end_pos = hit_info.position
		var c: Node = hit_info.get("collider", null)
		hit_player = c != null and c.has_meta(&"owner_player")
	var dist: float = muzzle_world.distance_to(end_pos)
	if dist < 0.5:
		return
	# Capped distance-scaled flight time so a sniper shot has visible travel
	# but close-range fire still feels snappy.
	var flight_time: float = clampf(0.05 + dist * 0.0025, 0.05, 0.25)
	# Hit-player tracers tint slightly red so even peripheral vision tells
	# the kid "you connected" vs "you missed".
	var trail_color: Color = Color(1, 0.45, 0.45) if hit_player else color

	# Bullet head — glowing sphere that flies from muzzle to impact.
	var bullet_head := MeshInstance3D.new()
	var bullet_mesh := SphereMesh.new()
	bullet_mesh.radius = 0.08
	bullet_mesh.height = 0.16
	bullet_mesh.radial_segments = 8
	bullet_mesh.rings = 4
	bullet_head.mesh = bullet_mesh
	bullet_head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bullet_mat := StandardMaterial3D.new()
	bullet_mat.albedo_color = trail_color
	bullet_mat.emission_enabled = true
	bullet_mat.emission = trail_color
	bullet_mat.emission_energy_multiplier = 6.5
	bullet_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bullet_head.material_override = bullet_mat
	tree.root.add_child(bullet_head)
	bullet_head.global_position = muzzle_world
	var ht: Tween = bullet_head.create_tween()
	ht.tween_property(bullet_head, "global_position", end_pos, flight_time)
	ht.tween_callback(bullet_head.queue_free)

	# Thin streak that fades behind the bullet head.
	var trail := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.04, 0.04, dist)
	trail.mesh = bm
	trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var trail_mat := StandardMaterial3D.new()
	trail_mat.albedo_color = Color(trail_color.r, trail_color.g, trail_color.b, 0.55)
	trail_mat.emission_enabled = true
	trail_mat.emission = trail_color
	trail_mat.emission_energy_multiplier = 3.0
	trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail.material_override = trail_mat
	tree.root.add_child(trail)
	trail.global_position = (muzzle_world + end_pos) * 0.5
	# look_at fails on collinear vectors (shot straight up/down). Skip orient.
	var dir_to_end: Vector3 = end_pos - trail.global_position
	if absf(dir_to_end.normalized().dot(Vector3.UP)) < 0.99 and dir_to_end.length() > 0.01:
		trail.look_at(end_pos, Vector3.UP, true)
	var tt: Tween = trail.create_tween()
	tt.tween_property(trail_mat, "albedo_color:a", 0.0, flight_time * 0.8)
	tt.parallel().tween_property(trail_mat, "emission_energy_multiplier", 0.0, flight_time * 0.8)
	tt.tween_callback(trail.queue_free)


## Floating Label3D billboarded above a remote player so the local human can
## SEE where the enemy is. Skipped for the local player's own avatar (you
## don't need to see your own name floating in first-person).
static func attach_name_tag(parent: Node, name_text: String) -> void:
	var tag := Label3D.new()
	tag.name = "_NameTag"
	tag.text = name_text
	tag.font_size = 48
	tag.outline_size = 12
	tag.outline_modulate = Color(0, 0, 0, 1)
	tag.modulate = Color(1, 0.85, 0.4, 1)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true  # render through walls so you can find enemies
	tag.pixel_size = 0.004
	tag.position = Vector3(0, 2.4, 0)  # above head
	parent.add_child(tag)
