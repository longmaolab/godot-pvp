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
const MapRegistry = preload("res://shared/data/map_registry.gd")

# Allowlist for map / mode resource paths. Without this, a malicious client
# can send any res:// string as `map_path` / `mode_def_path` and the server
# will load() it as a "map" / "mode" resource — turning room creation into a
# generic resource-loader.
const MODES_DIR := "res://shared/data/modes/"
var _valid_mode_paths: Dictionary = {}   # path String → true

const ROOM_ID_LENGTH := 4
const ROOM_ID_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/1/I/O — confusing in chat
const MAX_ROOMS := 10
const ID_GEN_MAX_ATTEMPTS := 32   # 32^4 = ~1M IDs, 10 rooms — collision basically impossible

# Emitted whenever a room's state changes (create / join / leave / state).
# GameController hooks this to push server_room_state RPCs out to the
# room's members so their UIs stay live without polling.
signal room_state_changed(room: Room)
# Emitted when a room is fully destroyed (host left / last player gone /
# explicit close). Carries the list of peers who were in the room at
# destruction time so the broadcaster can rpc_id to just them — by the
# time this signal fires, peer_to_room has already been cleared.
signal room_destroyed(room_id: String, evicted_peers: Array)
## A room just transitioned LOBBY → MATCH. GameController listens for
## this to load the room's map + spawn the room's players + broadcast
## server_match_starting to them.
signal match_started(room: Room)
## A room's match finished — GameController emits this back through after
## tearing down. Room is already back in LOBBY state by the time this
## fires. RoomManager broadcasts server_match_ended to room players so
## their game scenes transition back to room_lobby.tscn.
signal match_finished(room: Room)


var rooms: Dictionary = {}              # room_id (String) → Room
var peer_to_room: Dictionary = {}       # peer_id (int) → room_id (String)


func _ready() -> void:
	# Build the mode allowlist once at startup. (Maps come from MapRegistry's
	# static MAPS array — no scan needed.)
	_scan_mode_paths()
	# As an autoload, this _ready fires once per Godot process. Hook the
	# NetRpc signals so RPCs from clients land on our handlers. Each handler
	# gates on multiplayer.is_server() so this is harmless on a client-side
	# autoload instance (which still loads but never receives any of these).
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		push_warning("[RoomManager] NetRpc autoload not loaded — room RPCs will not work. Check project.godot autoload order.")
		return
	net_rpc.client_list_rooms_received.connect(_on_client_list_rooms)
	net_rpc.client_create_room_received.connect(_on_client_create_room)
	net_rpc.client_join_room_received.connect(_on_client_join_room)
	net_rpc.client_leave_room_received.connect(_on_client_leave_room)
	net_rpc.client_start_match_received.connect(_on_client_start_match)
	net_rpc.client_set_lobby_profile_received.connect(_on_client_set_lobby_profile)
	net_rpc.client_set_ready_received.connect(_on_client_set_ready)
	# Propagate room mutations out to room members via authority RPCs.
	room_state_changed.connect(_broadcast_room_state)
	room_destroyed.connect(_broadcast_room_destroyed)
	match_finished.connect(_broadcast_match_ended)
	# Defense-in-depth: GameController also calls leave_room on disconnect,
	# but only if the Game scene is loaded. Hooking here directly guarantees
	# room cleanup even if a peer disconnects during lobby (before any game
	# world exists) — otherwise their slot stays held until process restart.
	# leave_room is idempotent, so double-fire from both paths is safe.
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


## Create a new room owned by `host_peer`. Returns the room_id on success,
## empty string if at the global room cap.
func create_room(host_peer: int, map_path: String, mode_def_path: String) -> String:
	if rooms.size() >= MAX_ROOMS:
		print("[RoomMgr] create_room rejected: at cap %d" % MAX_ROOMS)
		return ""
	# Path allowlist — refuse any res:// string that isn't a known map / mode.
	# Empty mode_def_path is allowed (= Practice / no-mode FFA).
	if not _is_valid_map_path(map_path):
		print("[RoomMgr] create_room rejected: unknown map_path=%s" % map_path)
		return ""
	if not _is_valid_mode_path(mode_def_path):
		print("[RoomMgr] create_room rejected: unknown mode_def_path=%s" % mode_def_path)
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
	print("[RoomMgr] CREATE %s host=%d map=%s" % [room.room_id, host_peer, map_path.get_file()])
	room_state_changed.emit(room)
	return room.room_id


## Add `peer` to `room_id`. Returns true on success.
## Fails if the room doesn't exist, is full, or already in a match.
func join_room(peer: int, room_id: String) -> bool:
	if not rooms.has(room_id):
		print("[RoomMgr] JOIN peer=%d → %s rejected: room not found" % [peer, room_id])
		return false
	var room: Room = rooms[room_id]
	if room.is_full():
		print("[RoomMgr] JOIN peer=%d → %s rejected: room full (%d/%d)" % [peer, room_id, room.players.size(), room.max_players])
		return false
	if room.state != Room.STATE_LOBBY:
		print("[RoomMgr] JOIN peer=%d → %s rejected: state=%d not LOBBY" % [peer, room_id, room.state])
		return false   # mid-match — no late join in Phase 1
	# Already in another room? Leave it first (a peer can only be in one
	# room at a time).
	if peer_to_room.has(peer):
		if peer_to_room[peer] == room_id:
			return true   # idempotent: already here
		leave_room(peer)
	room.add_player(peer)
	peer_to_room[peer] = room_id
	print("[RoomMgr] JOIN %s peer=%d (now %d/%d players)" % [room_id, peer, room.players.size(), room.max_players])
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
		print("[RoomMgr] LEAVE peer=%d from %s (room missing — already destroyed?)" % [peer, room_id])
		return room_id   # defensive — shouldn't happen
	var room: Room = rooms[room_id]
	room.remove_player(peer)
	# Host left → destroy the room and evict remaining players.
	if peer == room.host_peer:
		print("[RoomMgr] LEAVE %s peer=%d (HOST) → destroy" % [room_id, peer])
		_destroy_room(room_id)
		return room_id
	# Regular player left → just notify the room.
	if room.is_empty():
		print("[RoomMgr] LEAVE %s peer=%d (last) → destroy" % [room_id, peer])
		_destroy_room(room_id)
	else:
		print("[RoomMgr] LEAVE %s peer=%d (non-host, %d/%d remain) → keep" % [room_id, peer, room.players.size(), room.max_players])
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


# ── RPC handlers ─────────────────────────────────────────────────────────
# Hooked in _ready, gated by multiplayer.is_server() so they no-op on a
# client-side autoload instance (every Godot process loads the autoload —
# only the DS / listen-host should actually process these).

func _on_client_list_rooms(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if not _peer_is_live(peer_id):
		return
	var net_rpc: Node = get_node(^"/root/NetRpc")
	net_rpc.server_room_list.rpc_id(peer_id, list_open_rooms())


func _on_client_create_room(peer_id: int, map_path: String, mode_def_path: String) -> void:
	if not multiplayer.is_server():
		return
	# Pre-validate so we can give the client a precise rejection reason.
	# create_room() repeats the same checks defensively — but those silently
	# return ""; here we want a typed message in the UI.
	var reject_reason: String = ""
	if not _is_valid_map_path(map_path):
		reject_reason = "无效地图"
	elif not _is_valid_mode_path(mode_def_path):
		reject_reason = "无效模式"
	if reject_reason.is_empty():
		var room_id: String = create_room(peer_id, map_path, mode_def_path)
		if not _peer_is_live(peer_id):
			return  # CRUD still happened; just don't try to reply to a non-live peer
		var net_rpc: Node = get_node(^"/root/NetRpc")
		if room_id.is_empty():
			net_rpc.server_room_join_failed.rpc_id(peer_id, "服务器房间已满 (10 房间上限)")
			return
		var room: Room = rooms[room_id]
		net_rpc.server_room_joined.rpc_id(peer_id, room_id, room.to_dict())
		return
	if not _peer_is_live(peer_id):
		return
	var net_rpc: Node = get_node(^"/root/NetRpc")
	net_rpc.server_room_join_failed.rpc_id(peer_id, reject_reason)


func _on_client_join_room(peer_id: int, room_id: String) -> void:
	if not multiplayer.is_server():
		return
	var success: bool = join_room(peer_id, room_id)
	if not _peer_is_live(peer_id):
		return  # CRUD still happened; just don't reply
	var net_rpc: Node = get_node(^"/root/NetRpc")
	if not success:
		var reason: String = "未知错误"
		if not rooms.has(room_id):
			reason = "房间不存在"
		elif rooms[room_id].is_full():
			reason = "房间已满"
		elif rooms[room_id].state != Room.STATE_LOBBY:
			reason = "对局已开始，无法中途加入"
		net_rpc.server_room_join_failed.rpc_id(peer_id, reason)
		return
	var room: Room = rooms[room_id]
	net_rpc.server_room_joined.rpc_id(peer_id, room_id, room.to_dict())


func _on_client_leave_room(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	# leave_room handles host-vs-non-host + emits room_state_changed or
	# room_destroyed which we broadcast below.
	leave_room(peer_id)


## Phase 2: peer is announcing their lobby identity. Updates the profile
## entry on the room they're in (no-op if they're not in one) and triggers
## a state broadcast so everyone else's lobby UI refreshes.
func _on_client_set_lobby_profile(peer_id: int, name: String, skin: int) -> void:
	if not multiplayer.is_server():
		return
	var room: Room = get_room_for_peer(peer_id)
	if room == null:
		return
	if room.set_profile(peer_id, name, skin):
		room_state_changed.emit(room)


## Phase 2: peer toggled their READY bit. Same broadcast pattern as
## set_lobby_profile but only fires when the bit actually flipped.
func _on_client_set_ready(peer_id: int, ready: bool) -> void:
	if not multiplayer.is_server():
		return
	var room: Room = get_room_for_peer(peer_id)
	if room == null:
		return
	# Host's ready bit is implicitly always-true (they own the START button),
	# so refuse to flip it — keeps the UI consistent regardless of stray RPCs.
	if peer_id == room.host_peer:
		return
	if room.set_ready(peer_id, ready):
		room_state_changed.emit(room)


## Phase 2 (F3): multiple rooms can be in MATCH simultaneously. The
## per-room World3D (RoomWorld SubViewport, F3-M1) gives each match its
## own physics space, and all server→client broadcasts are scoped to
## the room's player set (F3-M3c+M4) — so a peer in one match never
## sees another room's bullets, HP bars, kill feed, or geometry.
func _on_client_start_match(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	# Each reject path sends back a machine-readable reason so the client UI
	# can show a real message + re-enable the button. Silent returns used to
	# leave a joiner's "Play Again" frozen with no feedback.
	if not peer_to_room.has(peer_id):
		_send_start_match_failed(peer_id, "no_room")
		return
	var room_id: String = peer_to_room[peer_id]
	var room: Room = rooms.get(room_id, null)
	if room == null:
		_send_start_match_failed(peer_id, "room_gone")
		return
	if room.host_peer != peer_id:
		_send_start_match_failed(peer_id, "not_host")
		return
	if room.state == Room.STATE_MATCH:
		_send_start_match_failed(peer_id, "already_running")
		return
	start_match(room_id)


## Reply to the requester with a typed rejection so client UI can render
## a real status. Gated on _is_real_networked_server so headless unit tests
## (no real peer) can still call _on_client_start_match without "unknown
## peer ID" engine errors.
func _send_start_match_failed(peer_id: int, reason: String) -> void:
	if not _is_real_networked_server():
		return
	if not (peer_id in multiplayer.get_peers()):
		return
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.server_start_match_failed.rpc_id(peer_id, reason)


func start_match(room_id: String) -> void:
	var room: Room = rooms.get(room_id, null)
	if room == null:
		return
	print("[RoomMgr] START_MATCH %s (%d players)" % [room_id, room.players.size()])
	room.state = Room.STATE_MATCH
	# Wall-clock match start for match_history.started_ms (real time, not tick).
	room.match_started_ms = int(Time.get_unix_time_from_system() * 1000.0)
	room_state_changed.emit(room)   # tell room players the state changed
	match_started.emit(room)         # tell GameController to boot the match


## Called by GameController after the match controller's match_ended
## signal fires. Flips room back to LOBBY + broadcasts so all room
## players' game scenes return to room_lobby.tscn.
##
## winner_peer + final_scores are stashed on the Room BEFORE clear_scores
## wipes the live counters so the match-end broadcast can carry them to
## clients (DS client needs them to render the end-of-match summary).
func end_match(room_id: String, winner_peer: int = 0, final_scores: Dictionary = {}) -> void:
	var room: Room = rooms.get(room_id, null)
	if room == null:
		return
	print("[RoomMgr] END_MATCH %s → LOBBY (%d players, winner=%d)" % [room_id, room.players.size(), winner_peer])
	# Capture the result snapshot BEFORE clear_scores() wipes the live K/D.
	room.last_winner = winner_peer
	room.last_scores = final_scores.duplicate(true)
	room.state = Room.STATE_LOBBY
	# Force everyone to re-ready for round 2 — otherwise stale "ready"
	# bits from before the match carry over and host sees "all ready"
	# even though half the table is staring at the end-screen.
	room.clear_ready_bits()
	# Reset the per-room K/D counters so the next round starts from 0/0
	# (otherwise the scoreboard keeps accumulating across rematches).
	room.clear_scores()
	match_finished.emit(room)
	room_state_changed.emit(room)


func _broadcast_match_ended(room: Room) -> void:
	if not _is_real_networked_server():
		return
	var net_rpc: Node = get_node(^"/root/NetRpc")
	var state_dict: Dictionary = room.to_dict()
	var live: Array = multiplayer.get_peers()
	for peer in room.players:
		if peer in live:
			net_rpc.server_match_ended.rpc_id(peer, state_dict)


# Whether `peer_id` is currently connected to us as a server. Used to gate
# rpc_id calls so unit tests (which emit RPC signals with synthetic peer
# IDs) don't hit "Attempt to call RPC with unknown peer ID" engine errors.
# Production calls always pass — a peer's RPC handler only fires after the
# peer was admitted to the connection.
func _peer_is_live(peer_id: int) -> bool:
	if not _is_real_networked_server():
		return false
	return peer_id in multiplayer.get_peers()


## Remove a synthetic bot peer (negative id) from all room-side bookkeeping.
## Bots are registered by GameController._spawn_room_bots (which writes
## peer_to_room + room.players directly), so a match teardown must symmetrically
## purge them — otherwise rematches accumulate stale bot ids in room.players and
## the scoreboard. Real (positive) peers use leave_room instead; this is bots only.
func remove_bot(bot_peer_id: int) -> void:
	if bot_peer_id >= 0:
		return   # safety: synthetic bot ids are always negative
	var room_id: String = String(peer_to_room.get(bot_peer_id, ""))
	peer_to_room.erase(bot_peer_id)
	if room_id.is_empty() or not rooms.has(room_id):
		return
	var room: Room = rooms[room_id]
	room.players.erase(bot_peer_id)
	room.profiles.erase(bot_peer_id)
	room.kills.erase(bot_peer_id)
	room.deaths.erase(bot_peer_id)


# ── State broadcasters ───────────────────────────────────────────────────
# Hooked to room_state_changed / room_destroyed inside _ready. Gated on
# is_server() so client-side autoload instances don't try to call rpc_id
# on a peer connection they're not the authority for.

func _broadcast_room_state(room: Room) -> void:
	if not _is_real_networked_server():
		return
	var net_rpc: Node = get_node(^"/root/NetRpc")
	var state_dict: Dictionary = room.to_dict()
	# Filter to peers we actually have a connection to. Without this guard
	# unit tests (and any in-flight peer churn) trigger "Attempt to call
	# RPC with unknown peer ID" engine errors.
	var live: Array = multiplayer.get_peers()
	for peer in room.players:
		if peer in live:
			net_rpc.server_room_state.rpc_id(peer, state_dict)


func _broadcast_room_destroyed(room_id: String, evicted_peers: Array) -> void:
	if not _is_real_networked_server():
		return
	var net_rpc: Node = get_node(^"/root/NetRpc")
	var live: Array = multiplayer.get_peers()
	for peer in evicted_peers:
		if peer in live:
			net_rpc.server_room_destroyed.rpc_id(peer, room_id)


# Returns true only when there's a real network peer AND we're the server
# on it. OfflineMultiplayerPeer (Godot's default before create_server /
# create_client) reports is_server() == true even with no network at all,
# which is why every broadcaster needs this stricter check before calling
# rpc_id — otherwise headless tests spam "unknown peer ID" errors.
func _is_real_networked_server() -> bool:
	var p: MultiplayerPeer = multiplayer.multiplayer_peer
	if p == null or p is OfflineMultiplayerPeer:
		return false
	return multiplayer.is_server()


# ── Internals ─────────────────────────────────────────────────────────────

func _on_peer_disconnected(peer_id: int) -> void:
	# multiplayer.peer_disconnected fires on every node in every process, but
	# leave_room only makes sense on the authoritative server. Gating here
	# keeps client-side autoload instances inert.
	if not multiplayer.is_server():
		return
	leave_room(peer_id)


func _destroy_room(room_id: String) -> void:
	if not rooms.has(room_id):
		return
	var room: Room = rooms[room_id]
	# Capture the player list BEFORE clearing so listeners (e.g. the RPC
	# broadcaster) can target the evicted set with rpc_id.
	var evicted: Array = room.players.duplicate()
	print("[RoomMgr] DESTROY %s (was state=%d, evicting %s)" % [room_id, room.state, str(evicted)])
	# Evict any stragglers from peer_to_room (host already removed; this
	# handles the "host left while joiners were still in lobby" case).
	for peer in room.players:
		if peer_to_room.get(peer, "") == room_id:
			peer_to_room.erase(peer)
	rooms.erase(room_id)
	room_destroyed.emit(room_id, evicted)


func _is_valid_map_path(path: String) -> bool:
	for m in MapRegistry.MAPS:
		if String(m.path) == path:
			return true
	return false


func _is_valid_mode_path(path: String) -> bool:
	# Empty = Practice / no-mode, accepted intentionally.
	if path.is_empty():
		return true
	return _valid_mode_paths.has(path)


func _scan_mode_paths() -> void:
	_valid_mode_paths.clear()
	var dir := DirAccess.open(MODES_DIR)
	if dir == null:
		push_warning("[RoomMgr] cannot open %s — no mode allowlist" % MODES_DIR)
		return
	dir.list_dir_begin()
	while true:
		var fname: String = dir.get_next()
		if fname == "":
			break
		if dir.current_is_dir():
			continue
		# Web export rewrites .tres → .tres.remap (path indirection). Strip
		# the .remap suffix so the rest of the loop sees the original name.
		if fname.ends_with(".tres.remap"):
			fname = fname.substr(0, fname.length() - 6)
		if not fname.ends_with(".tres"):
			continue
		if fname.begins_with("_"):
			continue
		_valid_mode_paths[MODES_DIR + fname] = true
	dir.list_dir_end()


func _generate_room_id() -> String:
	for _attempt in ID_GEN_MAX_ATTEMPTS:
		var id := ""
		for _i in ROOM_ID_LENGTH:
			id += ROOM_ID_ALPHABET[randi() % ROOM_ID_ALPHABET.length()]
		if not rooms.has(id):
			return id
	return ""   # never happens with our scale — caller treats as cap-reached
