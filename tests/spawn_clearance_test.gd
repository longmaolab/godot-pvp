extends Node
## Regression test: every SpawnPoint on every map must be CLEAR of obstacle
## geometry, so respawning there doesn't trap the player/bot inside a wall.
##
## Why this exists (2026-05-31): blank.tscn had Spawn0 at (0,1,0) sitting
## INSIDE LowWallE (a 10×1.2×0.6 cover box centred at (0,0.6,0)). Players and
## room bots that respawned there materialised inside the wall — stuck in
## collision, unable to MOVE, but still able to turn (local aim) and shoot
## (separate fire RPC). User-reported as "重生大概率卡住 / bot 重生点卡在墙里".
##
## The check instantiates each map and tests every SpawnPoints/* Marker3D
## against every CSGBox3D obstacle's AABB (inflated by a capsule-radius
## margin). The huge floor box is skipped. No physics needed — pure geometry.

# Capsule radius + a little buffer. The player body is ~0.4-0.5 radius; 0.6
# leaves margin so a spawn that merely grazes a box still fails the test.
const MARGIN := 0.6
# Floor / ceiling slabs are this wide on at least one horizontal axis — skip
# them (you're meant to stand ON the floor, not be "inside" it).
const FLOOR_SPAN := 40.0

var failed: int = 0


func _ready() -> void:
	print("\n=== spawn clearance test (all maps) ===")
	var maps: PackedStringArray = _list_maps()
	if maps.is_empty():
		_fail("no map scenes found under res://shared/scenes/maps/")
	for map_path in maps:
		_check_map(map_path)
	print("\n=== result: %s (%d failures) ===" % ["PASS" if failed == 0 else "FAIL", failed])
	get_tree().quit(0 if failed == 0 else 1)


func _list_maps() -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open("res://shared/scenes/maps")
	if dir == null:
		return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.ends_with(".tscn"):
			out.append("res://shared/scenes/maps/" + f)
		f = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _check_map(map_path: String) -> void:
	var packed: PackedScene = load(map_path) as PackedScene
	if packed == null:
		_fail("%s: could not load" % map_path)
		return
	var root: Node = packed.instantiate()
	add_child(root)

	var spawn_root: Node = root.get_node_or_null(^"SpawnPoints")
	var spawns: Array = []
	if spawn_root != null:
		for c in spawn_root.get_children():
			if c is Marker3D:
				spawns.append(c)
	# Collect obstacle boxes (CSGBox3D) anywhere under the map.
	var boxes: Array = _collect_boxes(root)

	var hits: int = 0
	for s in spawns:
		var sp: Vector3 = (s as Node3D).global_position
		for b in boxes:
			var c: Vector3 = b["center"]
			var h: Vector3 = b["half"]
			# Trapped = the spawn ORIGIN sits strictly within the box's vertical
			# span (embedded mid-box, like inside a wall) AND its horizontal
			# footprint overlaps. A spawn resting ON a floor/platform has its
			# origin ABOVE the box top (sp.y >= c.y + h.y) → not flagged. Hence
			# the strict `< h.y` on Y (no standing-tolerance) vs a capsule-radius
			# margin on the horizontal axes.
			if absf(sp.x - c.x) <= h.x + MARGIN \
					and absf(sp.z - c.z) <= h.z + MARGIN \
					and absf(sp.y - c.y) < h.y:
				_fail("%s: %s %s is inside obstacle %s (center %s half %s)" % [
					map_path.get_file(), s.name, sp, b["name"], c, h])
				hits += 1
				break
	if hits == 0:
		print("  [ok] %s — %d spawns clear of %d boxes" % [map_path.get_file(), spawns.size(), boxes.size()])
	root.queue_free()


func _collect_boxes(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		# Only solid, collidable boxes can trap a body. Visual-only CSG
		# (use_collision = false — pickup glyphs, damage-pit decals, etc.)
		# and non-blocking Area3D pickups never stop movement, so spawning
		# on them is fine and must NOT be flagged.
		if child is CSGBox3D and (child as CSGBox3D).use_collision:
			var size: Vector3 = (child as CSGBox3D).size
			# Skip floor/ceiling slabs (huge on both horizontal axes).
			if not (size.x >= FLOOR_SPAN and size.z >= FLOOR_SPAN):
				out.append({
					"name": child.name,
					"center": (child as Node3D).global_position,
					"half": size * 0.5,
				})
		out.append_array(_collect_boxes(child))
	return out


func _fail(msg: String) -> void:
	push_error("[spawn-clearance] " + msg)
	print("  [FAIL] %s" % msg)
	failed += 1
