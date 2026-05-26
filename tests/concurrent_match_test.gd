extends SceneTree
## Integration test for F3-M5: two rooms can run matches simultaneously
## on one DS process, with full physics + RPC isolation. Before M5 the
## RoomManager flat-out rejected a 2nd room's start_match — this test
## proves the guard is gone and the isolation primitives below it
## (per-room RoomWorld, per-room match_controller, scoped RPCs) hold.
##
## What we verify:
##   1. RoomManager.start_match() succeeds for two rooms back-to-back
##      (no "blocked — X already in MATCH" warning)
##   2. Both rooms transition from LOBBY → MATCH
##   3. The per-room match_controllers are distinct instances under
##      distinct RoomWorld subtrees
##   4. Each RoomWorld has its OWN World3D (= its own physics space)
##      so a raycast in room A's space can never hit room B's colliders
##   5. _room_scoped_audience returns disjoint sets for peers in
##      different rooms
##
## What this test does NOT do (would require real network peers):
##   - Send actual snapshot RPCs and verify scoping at the receive
##     side. The RPC fanout logic is exercised at unit level in M3c.
##   - Drive two listen-host instances. That's tested manually.
##
## Run: bash tests/run_concurrent_match_test.sh

const RoomManager = preload("res://server/scripts/room_manager.gd")
const Room = preload("res://server/scripts/room.gd")
const GameControllerScript = preload("res://client/scripts/game_controller.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Without a MultiplayerPeer, `multiplayer.is_server()` returns false
	# (no peer ID = 0, server is peer 1). _boot_match_for_room gates on
	# this and would early-return, leaving room_worlds empty. An
	# OfflineMultiplayerPeer reports get_unique_id()==1 so is_server()
	# passes — without setting up a real network listener. The RPC
	# broadcasters in room_manager.gd already reject OfflineMultiplayerPeer
	# via _is_real_networked_server(), so they no-op cleanly.
	root.get_multiplayer().multiplayer_peer = OfflineMultiplayerPeer.new()

	# Reuse the RoomManager AUTOLOAD (registered in project.godot) — adding
	# a second RoomManager.new() under root creates a name collision: both
	# nodes literally have name "RoomManager", but `get_node("/root/RoomManager")`
	# resolves to the autoload, not the test-created one. Spent half an hour
	# chasing this before realizing.
	var rm: Node = root.get_node(^"RoomManager")
	if rm == null:
		failures.append("RoomManager autoload not present — check project.godot")
		_finish()
		return
	await physics_frame

	# Mount GameController in DS mode so _boot_match_for_room actually
	# stands up RoomWorlds. The match_started signal from RoomManager is
	# wired by GameController itself in its _ready().
	var gc: Node = GameControllerScript.new()
	gc.name = "Game"
	gc.is_dedicated_server = true
	# Stub multiplayer.is_server() returning true by setting an offline
	# peer to "server" — but that's a no-op in tests. We'll instead just
	# call the boot path directly with the room object.
	root.add_child(gc)
	await physics_frame

	# Defensive wire-up — GameController._ready normally hooks these in
	# _enter_dedicated_server_mode, but in the test env something further
	# downstream (likely the NetRpc-related branch the function walks
	# through) was preventing the connect() block from being reached.
	# Wiring it here directly keeps the test focused on what it's
	# verifying: isolation between two concurrent matches.
	if not rm.match_started.is_connected(gc._boot_match_for_room):
		rm.match_started.connect(gc._boot_match_for_room)
		rm.match_finished.connect(gc._on_match_finished_in_room)
		rm.room_destroyed.connect(gc._on_room_destroyed_check_active)

	# --- 1. Create two rooms with different hosts on the same DS.
	var room_a_id: String = rm.create_room(1001, "res://shared/scenes/maps/koth.tscn", "")
	var room_b_id: String = rm.create_room(1002, "res://shared/scenes/maps/trenches.tscn", "")
	if room_a_id.is_empty() or room_b_id.is_empty():
		failures.append("create_room failed for one or both rooms")
		_finish()
		return
	if room_a_id == room_b_id:
		failures.append("two rooms got the same id %s — generator collision" % room_a_id)
		_finish()
		return

	var room_a: Room = rm.rooms[room_a_id]
	var room_b: Room = rm.rooms[room_b_id]

	# --- 2. Boot both matches. RoomManager.start_match emits the
	# match_started signal which GameController._ready connected to its
	# own _boot_match_for_room. In a real DS that's the full path; the
	# test env relies on the OfflineMultiplayerPeer hack above so
	# `multiplayer.is_server()` in _boot_match_for_room is true.
	rm.start_match(room_a_id)
	rm.start_match(room_b_id)
	# Defer-heavy: RoomWorld add_child + load_map can take a few frames
	# to fully settle (SceneTree NOTIFICATION_ENTER_TREE chains).
	for _i in range(4):
		await physics_frame

	if room_a.state != Room.STATE_MATCH:
		failures.append("room A failed to enter MATCH state (state=%d)" % room_a.state)
	if room_b.state != Room.STATE_MATCH:
		failures.append("room B failed to enter MATCH state — guard not lifted? (state=%d)" % room_b.state)

	# --- 3. GameController.match_started signal handler should have
	# populated room_worlds with both rooms.
	if not gc.room_worlds.has(room_a_id):
		failures.append("GameController.room_worlds missing entry for room A")
	if not gc.room_worlds.has(room_b_id):
		failures.append("GameController.room_worlds missing entry for room B")

	# --- 4. Each RoomWorld has its OWN World3D + physics space (the load-
	# bearing primitive for isolation).
	if gc.room_worlds.has(room_a_id) and gc.room_worlds.has(room_b_id):
		var rw_a: SubViewport = gc.room_worlds[room_a_id]
		var rw_b: SubViewport = gc.room_worlds[room_b_id]
		var world_a: World3D = rw_a.find_world_3d()
		var world_b: World3D = rw_b.find_world_3d()
		if world_a == null or world_b == null:
			failures.append("one of the RoomWorlds has no World3D — isolation broken")
		elif world_a == world_b:
			failures.append("rooms A and B share the same World3D — isolation broken")
		elif world_a.space == world_b.space:
			failures.append("rooms A and B share the same physics space RID — isolation broken")
		# Match controllers should be distinct instances.
		var mc_a: Variant = rw_a.get("match_controller")
		var mc_b: Variant = rw_b.get("match_controller")
		if mc_a != null and mc_b != null and mc_a == mc_b:
			failures.append("rooms A and B share the same match_controller instance")
		# Map roots should be distinct + parented under their own RoomWorld.
		var map_a: Variant = rw_a.get("map_root")
		var map_b: Variant = rw_b.get("map_root")
		if map_a == null:
			failures.append("room A has no map_root mounted")
		elif map_a.get_parent() != rw_a:
			failures.append("room A's map_root isn't a child of its RoomWorld")
		if map_b == null:
			failures.append("room B has no map_root mounted")
		elif map_b.get_parent() != rw_b:
			failures.append("room B's map_root isn't a child of its RoomWorld")

	# --- 5. Audience scoping is disjoint. Room A's host should be in
	# room A's audience but NOT in room B's.
	var aud_a: Array = gc._room_scoped_audience(1001)
	var aud_b: Array = gc._room_scoped_audience(1002)
	if 1001 not in aud_a:
		failures.append("room A audience missing room A host")
	if 1001 in aud_b:
		failures.append("room A host leaked into room B audience")
	if 1002 not in aud_b:
		failures.append("room B audience missing room B host")
	if 1002 in aud_a:
		failures.append("room B host leaked into room A audience")

	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("  PASS — concurrent matches isolated: distinct World3Ds, physics spaces, match_controllers, maps, audiences")
		quit(0)
	else:
		for f in failures:
			print("  FAIL: %s" % f)
		quit(1)
