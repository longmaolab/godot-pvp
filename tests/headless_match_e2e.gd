extends Node
## DS match-mode end-to-end. Server boots with --mode ffa_kill5 (kill goal=5)
## AND --test-repeat-kill-interval 1.5, which makes the server kill peers[0]
## and credit peers[1] every 1.5 seconds. This drives MatchController toward
## its kill goal without depending on aim/raycast (which has a separate
## stale-cache issue tracked elsewhere). Both clients here are passive — they
## just connect and stay alive so the server has 2 peers to drive.
##
## Asserts (in run_match_e2e_test.sh):
##   - Server loaded mode=ffa_kill5
##   - Server logs >= 5 deaths
##   - Server logs "match ended — winner peer <peers[1]>"

const GAME_SCENE_PATH := "res://client/scenes/game.tscn"
const TICK_HZ := 30.0

var role: String = "A"
var address: String = "ws://127.0.0.1:9208"
var fire_seconds: float = 25.0

var game: Node = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--role" and i + 1 < args.size():
			role = args[i + 1]
		elif args[i] == "--address" and i + 1 < args.size():
			address = args[i + 1]
		elif args[i] == "--fire-seconds" and i + 1 < args.size():
			fire_seconds = float(args[i + 1])

	print("[%s] connect → %s" % [role, address])
	if not await _connect_and_mount():
		_die("connect failed")
		return
	game.local_player.is_human_input = false
	if not await _wait_for_peer_count(2, 6.0):
		_die("peer count never reached 2")
		return
	# Wait for snapshots to propagate REAL spawn positions (not initial 0,0,0
	# placeholder). We need both me.global_position and target.global_position
	# to be non-trivially apart before aim derivation is meaningful.
	var stable_deadline: float = Time.get_ticks_msec() / 1000.0 + 4.0
	while Time.get_ticks_msec() / 1000.0 < stable_deadline:
		var other: Node = _other_peer()
		if other != null and game.local_player.global_position.distance_to(other.global_position) > 5.0:
			break
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	if role == "A":
		var o: Node = _other_peer()
		if o != null:
			print("[A] me=%s target=%s dist=%.1f" % [
				str(game.local_player.global_position), str(o.global_position),
				game.local_player.global_position.distance_to(o.global_position)])

	# Both roles just idle; server-side hook drives the kill flow.
	await get_tree().create_timer(fire_seconds).timeout
	print("[%s] done" % role)
	get_tree().quit(0)


func _unused_shooter() -> void:
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		_die("A: no NetRpc")
		return
	var dt: float = 1.0 / TICK_HZ
	var elapsed: float = 0.0
	var tick: int = 0
	# Sanity gate: if target & me are essentially at the same point, the
	# computed aim degenerates (atan2(0,0)). Skip those ticks rather than
	# fire garbage upward into the void.
	var last_log_t: float = -10.0
	while elapsed < fire_seconds:
		var target: Node = _other_peer()
		if target != null and is_instance_valid(target):
			var me_pos: Vector3 = game.local_player.global_position
			var tgt_pos: Vector3 = target.global_position
			var planar_dist: float = Vector2(tgt_pos.x - me_pos.x, tgt_pos.z - me_pos.z).length()
			# Periodically log so we can see B's perceived position over time.
			if elapsed - last_log_t > 1.0:
				print("[A] t=%.1f target.pos=%s dist=%.2f target.is_dead=%s" % [
					elapsed, str(tgt_pos), planar_dist, target.is_dead])
				last_log_t = elapsed
			if planar_dist > 1.0 and not target.is_dead:
				var eye: Vector3 = me_pos + Vector3(0, 1.0, 0)
				var head_pos: Vector3 = tgt_pos + Vector3(0, 1.5, 0)
				var to: Vector3 = head_pos - eye
				var horiz: float = Vector2(to.x, to.z).length()
				var aim_yaw: float = atan2(to.x, to.z) + PI
				var aim_pitch: float = atan2(to.y, horiz)
				net_rpc.client_send_input.rpc_id(1, tick, NetProtocol.INPUT_FIRE, aim_yaw, aim_pitch)
				net_rpc.client_fire.rpc_id(1, &"ak20", aim_yaw, aim_pitch)
		tick += 1
		elapsed += dt
		await get_tree().create_timer(dt).timeout


func _unused_victim() -> void:
	await get_tree().create_timer(fire_seconds).timeout
	print("[B] done")


# ── Helpers ───────────────────────────────────────────────────────────────
func _other_peer() -> Node:
	for pid in game.players_by_peer.keys():
		var p: Node = game.players_by_peer[pid]
		if p != null and is_instance_valid(p) and not p.is_local:
			return p
	return null


func _connect_and_mount() -> bool:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(address)
	if err != OK:
		return false
	multiplayer.multiplayer_peer = peer
	var deadline: float = Time.get_ticks_msec() / 1000.0 + 5.0
	while peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			return false
		await get_tree().process_frame
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	print("[%s] peer_id=%d" % [role, multiplayer.get_unique_id()])
	var game_scene: PackedScene = load(GAME_SCENE_PATH) as PackedScene
	game = game_scene.instantiate()
	game.name = "Game"
	get_tree().root.add_child.call_deferred(game)
	await get_tree().process_frame
	await get_tree().create_timer(0.7).timeout
	var spawn_deadline: float = Time.get_ticks_msec() / 1000.0 + 4.0
	while Time.get_ticks_msec() / 1000.0 < spawn_deadline:
		var g: Node = get_tree().root.get_node_or_null(^"Game")
		if g != null and g.get("local_player") != null:
			game = g
			return true
		await get_tree().process_frame
	return false


func _wait_for_peer_count(want: int, seconds: float) -> bool:
	var deadline: float = Time.get_ticks_msec() / 1000.0 + seconds
	while Time.get_ticks_msec() / 1000.0 < deadline:
		if game != null and game.players_by_peer.size() == want:
			return true
		await get_tree().process_frame
	return false


func _die(msg: String) -> void:
	push_error("[%s] %s" % [role, msg])
	print("[%s] FAIL: %s" % [role, msg])
	get_tree().quit(1)
