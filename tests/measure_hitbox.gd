extends SceneTree
## One-off measurement: spawn a Player, apply each skin, print where the
## visible model's head actually lives vs the HeadHitbox sphere.
##
## Run: /Applications/Godot.app/Contents/MacOS/Godot --headless \
##        --path ~/projects/godot-pvp -s tests/measure_hitbox.gd

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const SKIN_COUNT := 18


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: PackedScene = load(PLAYER_SCENE) as PackedScene
	if scene == null:
		push_error("could not load player.tscn")
		quit(1)
		return

	var player: Node3D = scene.instantiate() as Node3D
	root.add_child(player)
	player.position = Vector3(0, 0.9, 0)

	print("=== HITBOX (static, from scene) ===")
	print("  HeadHitbox sphere: world Y ∈ [1.58, 2.22]  center 1.90  radius 0.32")
	print("  BodyHitbox capsule: world Y ∈ [0.00, 1.80] center 0.90  radius 0.40")
	print("  Camera/eye Y = 1.90")

	for idx in range(SKIN_COUNT):
		player.call("apply_skin", idx)
		await process_frame
		await process_frame
		_dump_skin(player, idx)

	print("=== done ===")
	OS.set_environment("MEASURE_DONE", "1")
	quit(0)
	# Godot --headless sometimes hangs after quit() if there are RIDs that
	# weren't released — force-kill our own process to make sure the script
	# returns to the shell.
	OS.kill(OS.get_process_id())


func _dump_skin(player: Node3D, idx: int) -> void:
	var holder: Node3D = player.get_node_or_null(^"Visuals/ModelHolder") as Node3D
	if holder == null or holder.get_child_count() == 0:
		print("[skin %d] no model loaded" % idx)
		return
	var model: Node3D = holder.get_child(0) as Node3D
	if model == null:
		print("[skin %d] holder child is not Node3D" % idx)
		return

	# Kenney characters: hierarchy of plain MeshInstance3D nodes (not skinned).
	# Walk it for a node literally named "head" / "torso".
	var head_mi: MeshInstance3D = _find_by_name(model, "head") as MeshInstance3D
	var torso_mi: MeshInstance3D = _find_by_name(model, "torso") as MeshInstance3D
	if head_mi == null:
		print("[skin %d] no 'head' MeshInstance3D found" % idx)
		return

	# Local AABB of the head mesh, transformed into world space.
	var head_local: AABB = head_mi.get_aabb()
	var head_world: AABB = head_mi.global_transform * head_local
	var head_origin_y: float = head_mi.global_transform.origin.y
	var head_top_y: float = head_world.position.y + head_world.size.y
	var head_bot_y: float = head_world.position.y
	var head_cen_y: float = (head_top_y + head_bot_y) * 0.5

	var torso_info := ""
	if torso_mi != null:
		var t_local: AABB = torso_mi.get_aabb()
		var t_world: AABB = torso_mi.global_transform * t_local
		torso_info = "  torso world Y ∈ [%.3f, %.3f]" % [
			t_world.position.y, t_world.position.y + t_world.size.y]

	print("[skin %2d] head origin Y=%.3f   head AABB world Y ∈ [%.3f, %.3f]   center=%.3f%s" %
		[idx, head_origin_y, head_bot_y, head_top_y, head_cen_y, torso_info])
	print("          Δ(head_center − sphere_center 1.90) = %+0.3f m" % (head_cen_y - 1.90))
	print("          Δ(head_top    − sphere_top    2.18) = %+0.3f m" % (head_top_y - 2.18))
	print("          Δ(head_bot    − sphere_bot    1.62) = %+0.3f m" % (head_bot_y - 1.62))


func _world_aabb(root_node: Node) -> AABB:
	var acc: AABB = AABB()
	var first := true
	var stack: Array = [root_node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).visible and (n as MeshInstance3D).mesh != null:
			var local: AABB = (n as MeshInstance3D).get_aabb()
			var world: AABB = (n as Node3D).global_transform * local
			if first:
				acc = world
				first = false
			else:
				acc = acc.merge(world)
		for c in n.get_children():
			stack.append(c)
	return acc


func _find_by_name(root_node: Node, target: String) -> Node:
	if root_node.name.to_lower() == target.to_lower():
		return root_node
	for c in root_node.get_children():
		var f: Node = _find_by_name(c, target)
		if f != null:
			return f
	return null


func _dump_tree(n: Node, depth: int) -> void:
	print("  ".repeat(depth) + "- %s (%s)" % [n.name, n.get_class()])
	for c in n.get_children():
		_dump_tree(c, depth + 1)


func _find_skeleton(root_node: Node) -> Skeleton3D:
	if root_node is Skeleton3D:
		return root_node
	for c in root_node.get_children():
		var s: Skeleton3D = _find_skeleton(c)
		if s != null:
			return s
	return null
