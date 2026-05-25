extends Node
## 30Hz authoritative tick loop. Owns the canonical world state for every
## match instance hosted by this server process.
##
## Per tick:
##   1. Drain queued client inputs into per-peer input buffer.
##   2. Step physics & movement for all entities (server-side simulation).
##   3. Process fire/ability inputs → hand off to HitValidator with lag-comp.
##   4. Record positions into history ring buffer (for future rewind).
##   5. Emit delta snapshot to every client in the match.

const TICK_RATE := 30
const TICK_DELTA := 1.0 / float(TICK_RATE)

var _tick: int = 0
var _accumulator: float = 0.0

# peer_id → InputBuffer (Array of {tick, bits, yaw, pitch}). Populated by
# RPC client_send_input. Drained at tick boundary.
var _input_queue: Dictionary = {}

# peer_id → Array of historical {tick, pos, yaw, pitch} snapshots for
# lag-compensation rewind. Cap at LAG_COMP_HISTORY_TICKS (~60 = 2s).
var _position_history: Dictionary = {}

@onready var hit_validator: Node = load("res://server/scripts/hit_validator.gd").new()

var _connected_peers: Array[int] = []


func _ready() -> void:
	add_child(hit_validator)
	print("[match_authority] online; tick rate = %d Hz" % TICK_RATE)
	# Wire RPC signal handlers (NetRpc is autoloaded; available on both sides
	# but only the server processes inbound client_* signals meaningfully).
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.client_hello_received.connect(_on_client_hello)
		net_rpc.client_input_received.connect(_on_client_input)
		net_rpc.client_fire_received.connect(_on_client_fire)
		net_rpc.client_chat_received.connect(_on_client_chat)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _on_peer_connected(peer_id: int) -> void:
	print("[match_authority] peer connected: ", peer_id)
	_connected_peers.append(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	print("[match_authority] peer disconnected: ", peer_id)
	_connected_peers.erase(peer_id)
	_input_queue.erase(peer_id)
	_position_history.erase(peer_id)


func _on_client_hello(peer_id: int, username: String) -> void:
	print("[match_authority] hello from %d (%s)" % [peer_id, username])
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.server_welcome.rpc_id(peer_id, peer_id, _tick)


func _on_client_input(peer_id: int, tick_no: int, bits: int, yaw: float, pitch: float) -> void:
	queue_input(peer_id, tick_no, bits, yaw, pitch)


func _on_client_fire(peer_id: int, weapon_id: StringName) -> void:
	# M2 will resolve via hit_validator with shooter's tracked position.
	print("[match_authority] peer %d fired %s (resolution deferred to M2)" % [peer_id, weapon_id])


func _on_client_chat(peer_id: int, text: String, color: Color) -> void:
	# Re-broadcast to every connected peer.
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		return
	net_rpc.server_chat_line.rpc(peer_id, text, color)


func _process(delta: float) -> void:
	# Decouple sim from render. _process drives the tick loop on the headless
	# server because we don't run _physics_process at our preferred rate.
	_accumulator += delta
	while _accumulator >= TICK_DELTA:
		_accumulator -= TICK_DELTA
		_tick += 1
		_run_tick(_tick)


func _run_tick(_tick_no: int) -> void:
	# 1. Drain inputs (TODO M1 when client_send_input RPC exists)
	# 2. Step movement (TODO M1 — needs Player.tscn)
	# 3. Process fire ops via hit_validator
	# 4. Record position history
	# 5. Broadcast snapshot
	pass


# Called by client_send_input RPC (registered on a separate node).
func queue_input(peer_id: int, tick_no: int, bits: int, yaw: float, pitch: float) -> void:
	if not _input_queue.has(peer_id):
		_input_queue[peer_id] = []
	_input_queue[peer_id].append({
		"tick": tick_no, "bits": bits, "yaw": yaw, "pitch": pitch,
	})
