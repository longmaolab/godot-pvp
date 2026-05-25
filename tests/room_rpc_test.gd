extends SceneTree
## Integration-ish test for the room RPC layer. Single process: opens a
## real WebSocketMultiplayerPeer as server (so `multiplayer.is_server()`
## reflects reality + `_is_real_networked_server()` lets broadcasts go),
## fires NetRpc signals manually as if they'd just arrived from a client,
## and asserts the corresponding server→client RPC is dispatched.
##
## Why this matters: the RoomManager handlers (M1 chunk B) translate
## client RPCs into RoomManager method calls + send replies. This test
## verifies that translation is wired correctly without needing a second
## process.
##
## What we can NOT test here (would need 2 processes):
##   - Actual rpc_id reaching a remote peer's NetRpc autoload.
##   - The receiving signal firing on the client side.
##
## Run: bash tests/run_room_rpc_test.sh

const MAP_PATH := "res://shared/scenes/maps/koth.tscn"

var failures: Array[String] = []
var net_rpc: Node = null
var room_mgr: Node = null

# We can't actually round-trip RPCs to a non-connected peer (engine errors
# with "unknown peer ID"). What we CAN do: observe room_state_changed and
# room_destroyed signals to verify the RoomManager handlers did call the
# CRUD methods correctly. The actual RPC dispatch is tested manually by
# running the DS + a real client.
var state_emissions: Array = []      # records each room_state_changed
var destroyed_emissions: Array = []  # records each room_destroyed


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	net_rpc = root.get_node_or_null(^"/root/NetRpc")
	room_mgr = root.get_node_or_null(^"/root/RoomManager")
	if net_rpc == null:
		failures.append("NetRpc autoload not found")
		_finish()
		return
	if room_mgr == null:
		failures.append("RoomManager autoload not found — check project.godot autoload list")
		_finish()
		return

	# Spin up a server peer so multiplayer.is_server() returns true (the
	# room manager autoload only acts when running as a real server).
	var peer := WebSocketMultiplayerPeer.new()
	var port: int = 9500 + (Time.get_ticks_msec() % 400)
	var err: int = peer.create_server(port)
	if err != OK:
		failures.append("create_server(%d) failed: %d" % [port, err])
		_finish()
		return
	root.multiplayer.multiplayer_peer = peer
	await physics_frame
	await physics_frame

	# Subscribe to RoomManager's outbound signals so we can assert the
	# right things happen in response to client RPC emissions.
	room_mgr.room_state_changed.connect(_on_state)
	room_mgr.room_destroyed.connect(_on_destroyed)

	# --- create_room: simulate client 1001 sending client_create_room.
	state_emissions.clear()
	net_rpc.client_create_room_received.emit(1001, MAP_PATH, "")
	await physics_frame
	if state_emissions.size() != 1:
		failures.append("create_room: expected 1 state emission, got %d" % state_emissions.size())
	elif state_emissions[0].host_peer != 1001:
		failures.append("create_room: room.host_peer = %d, expected 1001" % state_emissions[0].host_peer)
	if not room_mgr.peer_to_room.has(1001):
		failures.append("create_room: peer_to_room missing 1001")
	var room_id: String = room_mgr.peer_to_room.get(1001, "")

	# --- join_room: simulate client 1002 joining.
	state_emissions.clear()
	net_rpc.client_join_room_received.emit(1002, room_id)
	await physics_frame
	if state_emissions.size() != 1:
		failures.append("join_room: expected 1 state emission, got %d" % state_emissions.size())
	if not room_mgr.peer_to_room.has(1002):
		failures.append("join_room: peer_to_room missing 1002")

	# --- list_rooms: simulate client 1003 asking for the list. (This
	# doesn't emit a signal observable here; the handler calls rpc_id on
	# the server peer which would error to an unconnected client. Skip
	# direct verification — covered by integration when a real client
	# connects.)

	# --- leave_room (non-host): 1002 leaves, room survives.
	state_emissions.clear()
	destroyed_emissions.clear()
	net_rpc.client_leave_room_received.emit(1002)
	await physics_frame
	if state_emissions.size() != 1:
		failures.append("leave_room (non-host): expected 1 state emission, got %d" % state_emissions.size())
	if destroyed_emissions.size() != 0:
		failures.append("leave_room (non-host): emitted destroy unexpectedly: %s" % str(destroyed_emissions))
	if room_mgr.peer_to_room.has(1002):
		failures.append("leave_room (non-host): peer_to_room still has 1002")

	# --- leave_room (host): destroys the room.
	state_emissions.clear()
	destroyed_emissions.clear()
	net_rpc.client_leave_room_received.emit(1001)
	await physics_frame
	if destroyed_emissions.size() != 1:
		failures.append("leave_room (host): expected 1 destroyed emission, got %d" % destroyed_emissions.size())
	elif destroyed_emissions[0]["room_id"] != room_id:
		failures.append("leave_room (host): destroyed wrong room: got %s, expected %s" \
			% [destroyed_emissions[0]["room_id"], room_id])
	if room_mgr.rooms.has(room_id):
		failures.append("leave_room (host): room not removed from dict")

	# --- join_failed: try joining nonexistent room. We can't capture the
	# server_room_join_failed RPC here (no real client), but we can check
	# state isn't mutated.
	state_emissions.clear()
	destroyed_emissions.clear()
	net_rpc.client_join_room_received.emit(1004, "ZZZZ")
	await physics_frame
	if state_emissions.size() != 0:
		failures.append("join nonexistent: expected 0 state emissions, got %d" % state_emissions.size())
	if room_mgr.peer_to_room.has(1004):
		failures.append("join nonexistent: 1004 added to peer_to_room anyway")

	_finish()


func _on_state(room) -> void:
	state_emissions.append(room)


func _on_destroyed(room_id: String, evicted_peers: Array) -> void:
	destroyed_emissions.append({"room_id": room_id, "evicted": evicted_peers})


func _finish() -> void:
	if failures.is_empty():
		print("  PASS — RoomManager RPC handlers translate client emissions to correct CRUD + signals")
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
