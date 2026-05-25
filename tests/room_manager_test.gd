extends SceneTree
## Unit test for RoomManager — the server-side room registry that owns
## the data model for Phase 1 of the lobby system. This is the
## "do create / join / leave / list / host-leave-destroys work?" check;
## the RPC plumbing is a separate test in the integration tier.
##
## Run: bash tests/run_room_manager_test.sh

const RoomManager = preload("res://server/scripts/room_manager.gd")
const Room = preload("res://server/scripts/room.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var mgr: Node = RoomManager.new()
	root.add_child(mgr)
	await physics_frame

	# --- 1. create_room: returns 4-char ID, registers in dict + peer_to_room.
	var room_id: String = mgr.create_room(101, "res://shared/scenes/maps/koth.tscn", "")
	if room_id.length() != 4:
		failures.append("create_room returned id '%s' (length %d, expected 4)" % [room_id, room_id.length()])
	if not mgr.rooms.has(room_id):
		failures.append("create_room didn't register %s in rooms dict" % room_id)
	if mgr.peer_to_room.get(101, "") != room_id:
		failures.append("peer_to_room[101] != %s after create" % room_id)
	var room: Room = mgr.rooms[room_id]
	if room.host_peer != 101:
		failures.append("host_peer = %d, expected 101" % room.host_peer)
	if room.players != [101]:
		failures.append("players = %s, expected [101]" % str(room.players))
	if room.state != Room.STATE_LOBBY:
		failures.append("new room state %d, expected LOBBY(%d)" % [room.state, Room.STATE_LOBBY])

	# --- 2. join_room: second peer joins successfully.
	if not mgr.join_room(202, room_id):
		failures.append("join_room(202, %s) returned false" % room_id)
	if mgr.peer_to_room.get(202, "") != room_id:
		failures.append("peer_to_room[202] != %s after join" % room_id)
	if room.players != [101, 202]:
		failures.append("players = %s after 202 joined, expected [101, 202]" % str(room.players))

	# --- 3. join_room: idempotent on same peer + same room.
	if not mgr.join_room(202, room_id):
		failures.append("join_room idempotent call returned false")
	if room.players != [101, 202]:
		failures.append("players changed on idempotent join: %s" % str(room.players))

	# --- 4. join_room: nonexistent room rejected.
	if mgr.join_room(303, "ZZZZ"):
		failures.append("join_room of nonexistent room accepted")

	# --- 5. Full capacity (4 players max per Phase 1 lock).
	mgr.join_room(303, room_id)
	mgr.join_room(404, room_id)
	if room.players.size() != 4:
		failures.append("expected 4 players in full room, got %d" % room.players.size())
	# 5th peer rejected.
	if mgr.join_room(505, room_id):
		failures.append("5th peer joined a full room (max_players=4 not enforced)")

	# --- 6. leave_room (non-host) — just removes that peer.
	var left_id: String = mgr.leave_room(202)
	if left_id != room_id:
		failures.append("leave_room returned %s, expected %s" % [left_id, room_id])
	if mgr.peer_to_room.has(202):
		failures.append("peer_to_room still has 202 after leave")
	if 202 in room.players:
		failures.append("players still contains 202 after leave: %s" % str(room.players))
	if not mgr.rooms.has(room_id):
		failures.append("room destroyed after non-host left (should only destroy on host leave)")

	# --- 7. leave_room (host) — destroys room + evicts everyone.
	mgr.leave_room(101)   # 101 was the host
	if mgr.rooms.has(room_id):
		failures.append("room still exists after host left")
	if mgr.peer_to_room.has(303) or mgr.peer_to_room.has(404):
		failures.append("peer_to_room still has joiners after host-destroy: %s" % str(mgr.peer_to_room))

	# --- 8. MAX_ROOMS cap (10).
	var ids: Array = []
	for i in range(15):
		var id: String = mgr.create_room(1000 + i, "res://shared/scenes/maps/blank.tscn", "")
		if id != "":
			ids.append(id)
	if ids.size() != mgr.MAX_ROOMS:
		failures.append("MAX_ROOMS=%d but created %d rooms" % [mgr.MAX_ROOMS, ids.size()])
	# 11th creation should fail (returns "").
	var overflow_id: String = mgr.create_room(9999, "res://shared/scenes/maps/blank.tscn", "")
	if overflow_id != "":
		failures.append("11th room creation succeeded: %s (should fail at MAX_ROOMS cap)" % overflow_id)

	# --- 9. list_open_rooms returns summary objects, not full rooms.
	var listing: Array = mgr.list_open_rooms()
	if listing.size() != mgr.MAX_ROOMS:
		failures.append("list_open_rooms returned %d rooms, expected %d" % [listing.size(), mgr.MAX_ROOMS])
	if listing.size() > 0:
		var summary: Dictionary = listing[0]
		var expected_keys := ["id", "map", "mode", "count", "max", "state"]
		for k in expected_keys:
			if not summary.has(k):
				failures.append("summary missing key '%s' — got %s" % [k, str(summary.keys())])

	# --- 10. After destroying a room (free a slot), create_room succeeds
	# again. Verifies _destroy_room properly frees the dict entry.
	var slot_freed_id: String = ids[0]
	var slot_freed_host: int = mgr.rooms[slot_freed_id].host_peer
	mgr.leave_room(slot_freed_host)   # host leaves → room destroyed
	if mgr.rooms.size() != mgr.MAX_ROOMS - 1:
		failures.append("after destroying one room, rooms.size = %d, expected %d" \
			% [mgr.rooms.size(), mgr.MAX_ROOMS - 1])
	var fresh_id: String = mgr.create_room(8888, "res://shared/scenes/maps/blank.tscn", "")
	if fresh_id == "":
		failures.append("create_room failed after destroying one to free a slot")

	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("  PASS — RoomManager create/join/leave/list/cap all work")
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
