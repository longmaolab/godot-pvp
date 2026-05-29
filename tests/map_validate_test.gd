extends SceneTree
## New-map validation. For each freshly-authored map this:
##   1. Instantiates the .tscn (catches parse / bad-resource errors).
##   2. Requires a SpawnPoints node with >=2 markers + a DummySpawn.
##   3. Drops a physics-simulated player at every spawn marker and the dummy
##      spawn, lets it settle, and asserts it landed on solid ground — neither
##      fell through the floor (missing collision) nor got launched upward
##      (spawned inside geometry → Jolt depenetration runaway).
##
## This is the part of "is the map good" that's checkable headless. Layout
## feel (sightlines, cover balance) still needs a human walkthrough.
##
## Run: bash tests/run_map_validate_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const MAPS := [
	"res://shared/scenes/maps/crossfire.tscn",
	"res://shared/scenes/maps/longshot.tscn",
	"res://shared/scenes/maps/foundry.tscn",
]

var failures: Array[String] = []
var checks_done: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for map_path in MAPS:
		await _validate_map(map_path)
	_finish()


func _validate_map(map_path: String) -> void:
	var scene: PackedScene = load(map_path) as PackedScene
	if scene == null:
		failures.append("%s: failed to load (parse error / bad resource)" % map_path)
		return
	var map: Node3D = scene.instantiate() as Node3D
	if map == null:
		failures.append("%s: instantiate returned null" % map_path)
		return
	root.add_child(map)
	await physics_frame
	var label: String = map_path.get_file().get_basename()

	# Structure checks.
	var spawn_root: Node = map.get_node_or_null(^"SpawnPoints")
	if spawn_root == null or spawn_root.get_child_count() < 2:
		failures.append("%s: needs a SpawnPoints node with >=2 markers" % label)
		map.queue_free()
		await physics_frame
		return
	if map.get_node_or_null(^"DummySpawn") == null:
		failures.append("%s: missing DummySpawn marker" % label)
	checks_done += 1

	# Drop a player at each spawn + the dummy spawn, assert it lands.
	var drop_points: Array = []
	for c in spawn_root.get_children():
		if c is Node3D:
			drop_points.append([c.name, (c as Node3D).global_position])
	var dummy: Node3D = map.get_node_or_null(^"DummySpawn") as Node3D
	if dummy != null:
		drop_points.append(["DummySpawn", dummy.global_position])

	for dp in drop_points:
		var pt_name: String = dp[0]
		var pos: Vector3 = dp[1]
		var p: Node = await _drop_player(pos)
		if p == null:
			failures.append("%s/%s: could not spawn test player" % [label, pt_name])
			continue
		await _wait_seconds(1.0)   # settle under gravity
		var y: float = p.global_position.y
		# Body origin sits ~0.9 above the feet; a clean landing on the floor
		# (top at y=0) settles the origin near y≈0.9. Marker y is ~1.
		if y < pos.y - 1.5:
			failures.append("%s/%s: fell through (settled y=%.2f, spawn y=%.2f). Missing floor collision?" % [label, pt_name, y, pos.y])
		elif y > pos.y + 2.0:
			failures.append("%s/%s: launched upward (settled y=%.2f, spawn y=%.2f). Spawned inside geometry → Jolt depenetration." % [label, pt_name, y, pos.y])
		checks_done += 1
		# Also confirm it didn't drift wildly (spawned clipping a wall pushes it).
		var drift: float = Vector2(p.global_position.x - pos.x, p.global_position.z - pos.z).length()
		if drift > 3.0:
			failures.append("%s/%s: shoved %.1fm horizontally on spawn — marker is inside/touching geometry." % [label, pt_name, drift])
		p.queue_free()
		await physics_frame

	map.queue_free()
	await physics_frame


func _drop_player(pos: Vector3) -> Node:
	var scene: PackedScene = load(PLAYER_SCENE) as PackedScene
	if scene == null:
		return null
	var p: Node = scene.instantiate()
	# is_local + use_remote_input + zero bits = runs _step_movement (gravity +
	# collision) but takes no input, so it just falls and settles.
	p.is_local = true
	p.is_human_input = false
	p.use_remote_input = true
	p._remote_input_bits = 0
	root.add_child(p)
	p.global_position = pos
	await physics_frame
	return p


func _wait_seconds(t: float) -> void:
	var elapsed: float = 0.0
	while elapsed < t:
		await physics_frame
		elapsed += 1.0 / 60.0


func _finish() -> void:
	print("[map-validate] %d maps, %d checks" % [MAPS.size(), checks_done])
	if failures.is_empty():
		print("  PASS — all spawns land on solid ground, no fall-through / no spawn-in-wall")
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
