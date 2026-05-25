extends Area3D
class_name Pickup
## Ported + adapted from arena-shooter-3d/scripts/pickup.gd. Spinning, pulsing
## health kit or ammo crate. Walking over it heals / refills the entering
## player; the pickup hides for `respawn_time` seconds before returning.
##
## Differences from arena's version:
##   - Uses PlayerController's hp / loadout / _ammo_state directly (no
##     NetworkManager.players dictionary required).
##   - Falls back to local apply in practice mode (no MP peer) so the kit
##     works in singleplayer without networking setup.

@export_enum("health", "ammo") var pickup_type: String = "health"
@export var heal_amount: int = 50
@export var respawn_time: float = 25.0

const HEALTH_CORE := Color(0.96, 0.96, 0.96)
const HEALTH_CROSS := Color(0.96, 0.22, 0.32)
const AMMO_CRATE := Color(0.45, 0.32, 0.18)
const AMMO_LID := Color(1.0, 0.78, 0.26)

var _shared_emissive_mats: Array[StandardMaterial3D] = []


func _ready() -> void:
	if get_node_or_null("Visual") == null:
		_build_default_visual()
	if get_node_or_null("CollisionShape3D") == null:
		_build_default_collision()
	body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	rotate_y(delta * 1.4)
	var v: Node3D = get_node_or_null("Visual") as Node3D
	if v:
		v.position.y = 0.15 * sin(Time.get_ticks_msec() * 0.004)
	var pulse: float = 1.0 + 0.35 * sin(Time.get_ticks_msec() * 0.003)
	for mat in _shared_emissive_mats:
		mat.emission_energy_multiplier = pulse * 1.6


func _build_default_visual() -> void:
	var holder := Node3D.new()
	holder.name = "Visual"
	add_child(holder)
	if pickup_type == "health":
		_build_health_visual(holder)
	else:
		_build_ammo_visual(holder)


func _build_health_visual(holder: Node3D) -> void:
	var core_mat := StandardMaterial3D.new()
	core_mat.albedo_color = HEALTH_CORE
	core_mat.emission_enabled = true
	core_mat.emission = Color(0.85, 0.95, 0.90)
	core_mat.emission_energy_multiplier = 0.5
	core_mat.metallic = 0.1
	core_mat.roughness = 0.4
	var core := CSGBox3D.new()
	core.size = Vector3(0.55, 0.55, 0.55)
	core.material_override = core_mat
	holder.add_child(core)

	var cross_mat := StandardMaterial3D.new()
	cross_mat.albedo_color = HEALTH_CROSS
	cross_mat.emission_enabled = true
	cross_mat.emission = Color(1, 0.30, 0.40)
	cross_mat.emission_energy_multiplier = 1.6
	cross_mat.metallic = 0.0
	cross_mat.roughness = 0.35
	_shared_emissive_mats.append(cross_mat)

	for axis in [Vector3(0.78, 0.20, 0.20), Vector3(0.20, 0.78, 0.20), Vector3(0.20, 0.20, 0.78)]:
		var bar := CSGBox3D.new()
		bar.size = axis
		bar.material_override = cross_mat
		holder.add_child(bar)


func _build_ammo_visual(holder: Node3D) -> void:
	var crate_mat := StandardMaterial3D.new()
	crate_mat.albedo_color = AMMO_CRATE
	crate_mat.emission_enabled = true
	crate_mat.emission = Color(1, 0.72, 0.20)
	crate_mat.emission_energy_multiplier = 0.35
	crate_mat.metallic = 0.35
	crate_mat.roughness = 0.55
	var crate := CSGBox3D.new()
	crate.size = Vector3(0.72, 0.40, 0.52)
	crate.material_override = crate_mat
	holder.add_child(crate)

	var lid_mat := StandardMaterial3D.new()
	lid_mat.albedo_color = AMMO_LID
	lid_mat.emission_enabled = true
	lid_mat.emission = AMMO_LID
	lid_mat.emission_energy_multiplier = 1.4
	lid_mat.metallic = 0.55
	lid_mat.roughness = 0.30
	_shared_emissive_mats.append(lid_mat)

	var lid := CSGBox3D.new()
	lid.size = Vector3(0.78, 0.06, 0.56)
	lid.position = Vector3(0, 0.21, 0)
	lid.material_override = lid_mat
	holder.add_child(lid)

	var spine := CSGBox3D.new()
	spine.size = Vector3(0.06, 0.08, 0.56)
	spine.position = Vector3(0, 0.22, 0)
	spine.material_override = crate_mat
	holder.add_child(spine)


func _build_default_collision() -> void:
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var s := BoxShape3D.new()
	s.size = Vector3(1.4, 1.4, 1.4)
	col.shape = s
	add_child(col)


func _on_body_entered(body: Node) -> void:
	# In MP, only the host runs the consumption check; the result is
	# broadcast so everyone hides the pickup. In practice (offline) the
	# local player handles it directly.
	var is_local_practice: bool = not multiplayer.has_multiplayer_peer() \
		or (multiplayer.multiplayer_peer is OfflineMultiplayerPeer)
	if not is_local_practice and not multiplayer.is_server():
		return
	if not (body is CharacterBody3D):
		return
	if not body.is_in_group(&"player"):
		return
	var consumed: bool = false
	if pickup_type == "health":
		if body.hp < body.max_hp:
			body.hp = minf(body.max_hp, body.hp + float(heal_amount))
			body.hp_changed.emit(body.hp, body.max_hp)
			consumed = true
	elif pickup_type == "ammo":
		if "loadout" in body and body.loadout is Array:
			for w in body.loadout:
				if w == null:
					continue
				body._ammo_state[w.id] = {"in_mag": w.magazine, "reserve": w.reserve}
			if body.weapon_def != null:
				body._sync_ammo_from_state()
				body.ammo_changed.emit(body.ammo_in_mag, body.ammo_reserve)
			consumed = true
	if consumed:
		_disable_for_respawn()


func _disable_for_respawn() -> void:
	# Coordinated hide — broadcast in MP, local-only in practice.
	if multiplayer.has_multiplayer_peer() and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		_set_pickup_visible_rpc.rpc(false)
	else:
		_set_pickup_visible_local(false)
	await get_tree().create_timer(respawn_time).timeout
	if not is_inside_tree():
		return
	if multiplayer.has_multiplayer_peer() and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		_set_pickup_visible_rpc.rpc(true)
	else:
		_set_pickup_visible_local(true)


@rpc("authority", "reliable", "call_local")
func _set_pickup_visible_rpc(v: bool) -> void:
	_set_pickup_visible_local(v)


func _set_pickup_visible_local(v: bool) -> void:
	# Deferred because we may be inside the physics flush (body_entered fires
	# during area query processing — direct disable is illegal).
	visible = v
	set_deferred("monitoring", v)
	var col: CollisionShape3D = get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col:
		col.set_deferred("disabled", not v)
