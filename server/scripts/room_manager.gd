extends Node
## Server-side room registry. One per DS process (autoloaded). Maintains
## the rooms dict + peer-to-room lookup that everything else uses to
## scope gameplay RPCs to a single match's audience.
##
## All mutation goes through RoomManager so peer_to_room is never out of
## sync with rooms[room_id].players — that pair of dicts is the only
## source of truth for "who's in what room right now".
##
## Phase 1 scope (per .agent/lobby_plan.md):
##   - create / list / join / leave
##   - 10 rooms max, 4 players per room
##   - 4-char alphanumeric room IDs (collisions retry up to 32 times)
##   - host leaves → room destroyed; surviving members get evicted
##   - peer disconnect → leave_room cleanup
##
## What this class does NOT do (handled elsewhere):
##   - RPC plumbing (that's GameController / NetRpc on the network edge)
##   - match start / end (that's MatchController, scoped per-room later)
##   - peer authentication (no anti-griefing in Phase 1)

const Room = preload("res://server/scripts/room.gd")

const ROOM_ID_LENGTH := 4
const ROOM_ID_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/1/I/O — confusing in chat
const MAX_ROOMS := 10
const ID_GEN_MAX_ATTEMPTS := 32   # 32^4 = ~1M IDs, 10 rooms — collision basically impossible

# Emitted whenever a room's state changes (create / join / leave / state).
# GameController hooks this to push server_room_state RPCs out to the
# room's members so their UIs stay live without polling.
signal room_state_changed(room: Room)
# Emitted when a room is fully destroyed (host left / last player gone /
# explicit close). Triggers eviction RPCs + cleanup of any per-room
# gameplay state (player nodes, lag-comp history, etc).
signal room_destroyed(room_id: String)


var rooms: Dictionary = {}              # room_id (String) → Room
var peer_to_room: Dictionary = {}       # peer_id (int) → room_id (String)


## Create a new room owned by `host_peer`. Returns the room_id on success,
## empty string if at the global room cap.
func create_room(host_peer: int, map_path: String, mode_def_path: String) -> String:
	if rooms.size() >= MAX_ROOMS:
		return ""
	# If this peer is already in a room, kick them out of it first — a
	# create implies they're starting over.
	if peer_to_room.has(host_peer):
		leave_room(host_peer)
	var room := Room.new()
	room.room_id = _generate_room_id()
	if room.room_id.is_empty():
		# ID generator gave up — astronomically unlikely with our alphabet
		# but bail rather than risk a duplicate.
		return ""
	room.host_peer = host_peer
	room.map_path = map_path
	room.mode_def_path = mode_def_path
	room.created_at_ms = Time.get_ticks_msec()
	room.add_player(host_peer)
	rooms[room.room_id] = room
	peer_to_room[host_peer] = room.room_id
	room_state_changed.emit(room)
	return room.room_id


## Add `peer` to `room_id`. Returns true on success.
## Fails if the room doesn't exist, is full, or already in a match.
func join_room(peer: int, room_id: String) -> bool:
	if not rooms.has(room_id):
		return false
	var room: Room = rooms[room_id]
	if room.is_full():
		return false
	if room.state != Room.STATE_LOBBY:
		return false   # mid-match — no late join in Phase 1
	# Already in another room? Leave it first (a peer can only be in one
	# room at a time).
	if peer_to_room.has(peer):
		if peer_to_room[peer] == room_id:
			return true   # idempotent: already here
		leave_room(peer)
	room.add_player(peer)
	peer_to_room[peer] = room_id
	room_state_changed.emit(room)
	return true


## Remove `peer` from whatever room they're in. Returns the room_id they
## were in (empty if none). If the leaver was the host, destroy the room
## (per Phase 1 decision — Q6 in lobby_plan).
func leave_room(peer: int) -> String:
	if not peer_to_room.has(peer):
		return ""
	var room_id: String = peer_to_room[peer]
	peer_to_room.erase(peer)
	if not rooms.has(room_id):
		return room_id   # defensive — shouldn't happen
	var room: Room = rooms[room_id]
	room.remove_player(peer)
	# Host left → destroy the room and evict remaining players.
	if peer == room.host_peer:
		_destroy_room(room_id)
		return room_id
	# Regular player left → just notify the room.
	if room.is_empty():
		_destroy_room(room_id)
	else:
		room_state_changed.emit(room)
	return room_id


## Browser list — every active room, summarized.
func list_open_rooms() -> Array:
	var out: Array = []
	for room_id in rooms.keys():
		var r: Room = rooms[room_id]
		if r.state == Room.STATE_LOBBY:
			out.append(r.to_summary())
	return out


func get_room_for_peer(peer: int) -> Room:
	if not peer_to_room.has(peer):
		return null
	var room_id: String = peer_to_room[peer]
	return rooms.get(room_id, null)


func get_room(room_id: String) -> Room:
	return rooms.get(room_id, null)


# ── Internals ─────────────────────────────────────────────────────────────

func _destroy_room(room_id: String) -> void:
	if not rooms.has(room_id):
		return
	var room: Room = rooms[room_id]
	# Evict any stragglers from peer_to_room (host already removed; this
	# handles the "host left while joiners were still in lobby" case).
	for peer in room.players:
		if peer_to_room.get(peer, "") == room_id:
			peer_to_room.erase(peer)
	rooms.erase(room_id)
	room_destroyed.emit(room_id)


func _generate_room_id() -> String:
	for _attempt in ID_GEN_MAX_ATTEMPTS:
		var id := ""
		for _i in ROOM_ID_LENGTH:
			id += ROOM_ID_ALPHABET[randi() % ROOM_ID_ALPHABET.length()]
		if not rooms.has(id):
			return id
	return ""   # never happens with our scale — caller treats as cap-reached
