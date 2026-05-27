extends Node3D
## Client-side proxy for a server-spawned throwable projectile.
## Spawned in response to server_throwable_spawn RPC; integrates the SAME
## gravity-driven physics as throwable_projectile.gd on the server, so the
## client's local trajectory tracks the server's without per-tick position
## sync. Freed by GameController._on_throwable_explode after spawning VFX.
##
## Visual: small luminous sphere with a colored trail. Doesn't have to be
## pixel-perfect — the throw is short (1-3s) and the player needs to
## *see* the arc, not measure it.

const GRAVITY := 9.8
const SUBSTEP := 0.05

var weapon: Resource = null   # WeaponDef — for color cues and explode_radius (debug)
var velocity: Vector3 = Vector3.ZERO
var elapsed: float = 0.0


func _ready() -> void:
	# Build a simple sphere mesh with an emissive material. Done in code
	# so adding new throwables doesn't require a per-weapon scene file.
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.08
	sphere.height = 0.16
	sphere.radial_segments = 12
	sphere.rings = 6
	mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = weapon.bullet_color if weapon != null else Color(0.95, 0.7, 0.3)
	mat.emission_enabled = true
	mat.emission = mat.albedo_color
	mat.emission_energy_multiplier = 2.0
	mesh.material_override = mat
	add_child(mesh)


func _physics_process(delta: float) -> void:
	# Same substep + gravity as server throwable_projectile.gd. Client doesn't
	# need to do contact / fuse / damage — server runs that authoritatively
	# and ends our life via server_throwable_explode RPC.
	var remaining: float = delta
	while remaining > 0.0:
		var step: float = minf(remaining, SUBSTEP)
		remaining -= step
		elapsed += step
		velocity.y -= GRAVITY * step
		global_position += velocity * step


## Quick + cheap explosion VFX. Free-floating particle node + light flash;
## cleans itself up after `lifetime` seconds. Called by GameController's
## _on_throwable_explode handler at the broadcast `position`.
static func spawn_explosion_vfx(parent: Node, position: Vector3, color: Color, radius: float) -> void:
	var root := Node3D.new()
	root.global_position = position
	parent.add_child(root)
	# Bright instantaneous flash via OmniLight3D — bumps + decays.
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 4.0
	light.omni_range = max(radius * 2.0, 6.0)
	root.add_child(light)
	# Particle burst.
	var particles := GPUParticles3D.new()
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 180.0
	mat.initial_velocity_min = radius * 1.2
	mat.initial_velocity_max = radius * 2.5
	mat.gravity = Vector3(0, -6, 0)
	mat.color = color
	mat.scale_min = 0.1
	mat.scale_max = 0.3
	particles.process_material = mat
	var pmesh := SphereMesh.new()
	pmesh.radius = 0.1
	pmesh.height = 0.2
	particles.draw_pass_1 = pmesh
	particles.amount = 40
	particles.lifetime = 0.55
	particles.one_shot = true
	particles.explosiveness = 0.95
	root.add_child(particles)
	particles.restart()
	# Auto-cleanup 1s after spawn — particle lifetime + light decay both
	# fit inside that window. instance_id capture so a scene change mid-flight
	# doesn't crash on null Node.
	var rid: int = root.get_instance_id()
	parent.get_tree().create_timer(1.0).timeout.connect(
		func():
			var n: Object = instance_from_id(rid)
			if n != null and is_instance_valid(n):
				n.queue_free()
	)
	# Light fades over the first 0.4s for a punchy flash.
	var t: Tween = root.create_tween()
	t.tween_property(light, "light_energy", 0.0, 0.4)
