extends Node
## DS-only autoload. Records every client_input_received RPC (peer, tick,
## bits, yaw, pitch) into an in-memory buffer keyed by room_id. On
## match_finished signal from RoomManager, flushes the buffer for that
## room to `user://replays/<room_id>_<timestamp>.json`.
##
## On Linux VPS user:// resolves to /root/.local/share/godot/app_userdata/
## godot-pvp/replays/ (verify with godot --headless and check the path).
## For now this is just a write-only sink — playback is a separate scene
## that reads the JSON and re-runs the inputs against a fresh world.
##
## Anti-cheat secondary use: a suspicious peer's input trace lets a human
## moderator review whether their movement / aim deltas match human
## constraints. push_warning hits would tag the replay file for review.

const REPLAY_DIR := "user://replays/"
const MAX_FRAMES_PER_MATCH := 50000   # ~14 min at 60Hz; cap memory


# In-memory buffer: room_id (String) → Array of input dicts.
var _buffers: Dictionary = {}
# Parallel position-snapshot buffer for VISUAL playback: room_id → Array of
# { t, s:[[peer,x,y,z,ry], ...] }. Input frames (`_buffers`) drive anti-cheat
# review; these drive the replay viewer's ghost players (no physics re-sim).
var _snap_buffers: Dictionary = {}
const SNAP_HZ := 10.0
var _snap_timer: Timer = null
var _ready_for_record: bool = false


func _ready() -> void:
	# Client-side autoload instances stay inert. Only the DS records.
	if not NetProtocol.is_dedicated_server_boot():
		return
	_ready_for_record = true
	# Ensure replay dir exists.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REPLAY_DIR))
	# Position sampler — fires SNAP_HZ times/sec while any match is recording.
	_snap_timer = Timer.new()
	_snap_timer.wait_time = 1.0 / SNAP_HZ
	_snap_timer.autostart = true
	_snap_timer.timeout.connect(_sample_positions)
	add_child(_snap_timer)
	# Hook input stream as soon as NetRpc is up.
	call_deferred("_wire_signals")


# Sample every active room's player positions into _snap_buffers. Reads the
# live game world (/root/Game.players_by_peer) + RoomManager.peer_to_room.
func _sample_positions() -> void:
	if not _ready_for_record or _snap_buffers.is_empty():
		return
	var game: Node = get_node_or_null(^"/root/Game")
	var rm: Node = get_node_or_null(^"/root/RoomManager")
	if game == null or rm == null or not "players_by_peer" in game:
		return
	var now: int = Time.get_ticks_msec()
	# Build per-room snapshot arrays in one pass over players.
	var per_room: Dictionary = {}   # room_id → Array of [peer,x,y,z,ry]
	for peer in game.players_by_peer.keys():
		var p: Node = game.players_by_peer[peer]
		if p == null or not is_instance_valid(p):
			continue
		var rid: String = String(rm.peer_to_room.get(peer, ""))
		if rid.is_empty() or not _snap_buffers.has(rid):
			continue
		var pos: Vector3 = p.global_position
		var arr: Array = per_room.get(rid, [])
		arr.append([peer, snappedf(pos.x, 0.01), snappedf(pos.y, 0.01), snappedf(pos.z, 0.01), snappedf(p.rotation.y, 0.01)])
		per_room[rid] = arr
	for rid in per_room.keys():
		var buf: Array = _snap_buffers[rid]
		if buf.size() >= MAX_FRAMES_PER_MATCH:
			continue
		buf.append({"t": now, "s": per_room[rid]})


func _wire_signals() -> void:
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		push_warning("[ReplayRecorder] NetRpc autoload missing")
		return
	net_rpc.client_input_received.connect(_on_client_input)
	var rm: Node = get_node_or_null(^"/root/RoomManager")
	if rm != null:
		# Start a fresh buffer when a room enters a match.
		if rm.has_signal(&"match_started"):
			rm.match_started.connect(_on_match_started)
		# Flush + clear on match finished.
		if rm.has_signal(&"match_finished"):
			rm.match_finished.connect(_on_match_finished)


func _on_client_input(peer_id: int, tick: int, bits: int, yaw: float, pitch: float) -> void:
	if not _ready_for_record:
		return
	# Resolve room by peer.
	var rm: Node = get_node_or_null(^"/root/RoomManager")
	if rm == null:
		return
	var room_id: String = String(rm.peer_to_room.get(peer_id, ""))
	if room_id.is_empty():
		return
	var buf: Array = _buffers.get(room_id, [])
	if buf.size() >= MAX_FRAMES_PER_MATCH:
		return   # ring-cap; don't grow memory unbounded
	buf.append({
		"t":  Time.get_ticks_msec(),
		"p":  peer_id,
		"k":  tick,
		"b":  bits,
		"y":  yaw,
		"pt": pitch,
	})
	_buffers[room_id] = buf


func _on_match_started(room: Variant) -> void:
	if not _ready_for_record or room == null:
		return
	var room_id: String = String(room.room_id) if "room_id" in room else ""
	if not room_id.is_empty():
		_buffers[room_id] = []
		_snap_buffers[room_id] = []


func _on_match_finished(room: Variant) -> void:
	if not _ready_for_record or room == null:
		return
	var room_id: String = String(room.room_id) if "room_id" in room else ""
	if room_id.is_empty():
		return
	var buf: Array = _buffers.get(room_id, [])
	if buf.is_empty():
		return
	# Write to disk. Filename: <room>_<unix-ms>.json so old replays don't
	# collide across server lifetimes.
	var ts: int = int(Time.get_unix_time_from_system() * 1000.0)
	var path: String = "%s%s_%d.json" % [REPLAY_DIR, room_id, ts]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[ReplayRecorder] failed to open %s" % path)
		_buffers.erase(room_id)
		return
	# Header carries metadata for the playback scene. `frames` = input trace
	# (anti-cheat / analysis); `snapshots` = 10Hz position stream (visual
	# replay viewer renders ghosts from these).
	var snaps: Array = _snap_buffers.get(room_id, [])
	var payload: Dictionary = {
		"version": 2,
		"room_id": room_id,
		"frames":  buf,
		"snapshots": snaps,
		"snap_hz": SNAP_HZ,
		"saved_at_ms": ts,
		"frame_count": buf.size(),
		"snapshot_count": snaps.size(),
	}
	f.store_string(JSON.stringify(payload))
	f.close()
	print("[replay] saved %d frames + %d snapshots → %s" % [buf.size(), snaps.size(), path])
	_buffers.erase(room_id)
	_snap_buffers.erase(room_id)
