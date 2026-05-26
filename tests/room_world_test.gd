extends SceneTree
## Unit test for RoomWorld — the per-room SubViewport container that
## F3-M1 introduced. M1 only stands up the lifecycle (create / free) and
## the world-isolation primitive (own_world_3d). Map / players / match
## are still on GameController until later milestones.
##
## What we assert here:
##   1. RoomWorld instances stand up under add_child without errors
##   2. Each RoomWorld has its OWN World3D (not the shared default one),
##      which is the entire reason this class exists
##   3. Two concurrent RoomWorlds get DIFFERENT World3Ds (so room A's
##      physics space can't accidentally be room B's)
##   4. The pre-allocated players_root child exists and is named "Players"
##   5. queue_free() cleans up without leaks
##
## Run: bash tests/run_room_world_test.sh

const RoomWorld = preload("res://server/scripts/room_world.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# --- 1. instantiate cleanly
	var rw_a: SubViewport = RoomWorld.new()
	rw_a.room_id = "AXJ7"
	root.add_child(rw_a)
	await physics_frame

	# Viewport.world_3d returns only the EXPLICITLY assigned world; the
	# effective world (own when own_world_3d=true, parent's otherwise) is
	# what find_world_3d returns. That's the field we care about — the one
	# physics queries actually use.
	var world_a: World3D = rw_a.find_world_3d()
	if world_a == null:
		failures.append("rw_a.find_world_3d() is null — viewport never resolved a world")

	if not rw_a.own_world_3d:
		failures.append("rw_a.own_world_3d is false — class _init didn't set it")

	# --- 4. players_root pre-allocated
	var players_node: Node = rw_a.get_node_or_null(^"Players")
	if players_node == null:
		failures.append("RoomWorld didn't create the Players child node")
	elif not (players_node is Node3D):
		failures.append("RoomWorld 'Players' child is %s, expected Node3D" % players_node.get_class())

	if rw_a.players_root == null:
		failures.append("RoomWorld.players_root field not assigned")

	# --- 2 + 3. spin up a second RoomWorld and confirm its World3D is distinct
	var rw_b: SubViewport = RoomWorld.new()
	rw_b.room_id = "K2P4"
	root.add_child(rw_b)
	await physics_frame

	var world_b: World3D = rw_b.find_world_3d()
	if world_b == null:
		failures.append("rw_b.find_world_3d() is null")
	elif world_a != null and world_a == world_b:
		# This is THE invariant for concurrent rooms — same World3D means
		# raycasts in room A can hit colliders in room B.
		failures.append("rw_a and rw_b share the same World3D — isolation broken")
	elif world_a != null and world_b != null and world_a.space == world_b.space:
		# Even if World3D objects are distinct, what physics actually scopes
		# by is the PhysicsServer3D space RID. If those collide, isolation
		# is fake. (Should never happen with own_world_3d=true, but assert.)
		failures.append("rw_a/rw_b have the same physics space RID — isolation broken")

	# --- 5. load_map happy path: map appears under the SubViewport
	var map_node: Node3D = rw_a.load_map("res://shared/scenes/maps/blank.tscn")
	if map_node == null:
		failures.append("load_map returned null for a valid map path")
	elif map_node.get_parent() != rw_a:
		failures.append("load_map didn't parent the map under the SubViewport")

	# --- 5b. load_map fallback path: garbage path → blank.tscn fallback
	var fallback_map: Node3D = rw_b.load_map("res://does/not/exist.tscn")
	if fallback_map == null:
		failures.append("load_map didn't fall back to blank.tscn for bad path")

	# --- 6. queue_free cleans up (no leak warning at exit)
	rw_a.queue_free()
	rw_b.queue_free()
	await physics_frame
	await physics_frame

	if failures.is_empty():
		print("  PASS — RoomWorld lifecycle + per-room World3D isolation work")
		quit(0)
	else:
		for f in failures:
			print("  FAIL: %s" % f)
		quit(1)
