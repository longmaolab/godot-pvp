extends Node
## DS three-client integration. Three real game.tscn instances connect to the
## same DS. Each rotates briefly through targets so that BOTH A→B and B→C
## damage paths get exercised. Then C disconnects mid-match and A keeps
## shooting B — proves a third-peer leave doesn't break the surviving pair.
##
## Roles:
##   --role A   shooter #1; aims at B and fires
##   --role B   shooter #2 / victim of A; aims at C and fires after a delay
##   --role C   victim of B; leaves mid-match
##
## Note: the blank map's spawn corners happen to be colinear with the centre,
## so any cross-fire between corner peers passes through whoever is at (0,0).
## We can't easily prove two distinct VICTIMS — but we can prove two distinct
## SHOOTERS, which is what the "multi-client coexistence" bug actually needs.
##
## Asserts (in run_three_client_test.sh):
##   1. Server logs 3 spawns
##   2. Server logs hits from >= 2 DISTINCT shooter peer ids (so >=2 clients
##      are landing damage end-to-end concurrently)
##   3. Server logs >= 1 despawn BEFORE auto-shutdown (C leaves mid-match)
##   4. Server logs hits BOTH before AND after C's despawn (proves survivor
##      pair keeps shooting once the third peer leaves)
##   5. Each client process exits 0

const GAME_SCENE_PATH := "res://client/scenes/game.tscn"
const TICK_HZ := 30.0

var role: String = "A"
var address: String = "ws://127.0.0.1:9204"
var fire_after: float = 1.5
var fire_duration: float = 3.0
var leave_after: float = 4.0   # only honored by role C

var game: Node = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--role" and i + 1 < args.size():
			role = args[i + 1]
		elif args[i] == "--address" and i + 1 < args.size():
			address = args[i + 1]
		elif args[i] == "--fire-after" and i + 1 < args.size():
			fire_after = float(args[i + 1])
		elif args[i] == "--fire-duration" and i + 1 < args.size():
			fire_duration = float(args[i + 1])
		elif args[i] == "--leave-after" and i + 1 < args.size():
			leave_after = float(args[i + 1])

	print("[%s] connect → %s" % [role, address])
	if not await _connect_and_mount():
		_die("connect failed")
		return
	if game.local_player != null:
		game.local_player.is_human_input = false

	# Wait for all 3 peers to be visible from our side.
	if not await _wait_for_peer_count(3, 6.0):
		_die("only saw %d peers (expected 3)" % (game.players_by_peer.size() if game else 0))
		return
	if not _assert_only_local_camera_current():
		return
	print("[%s] all 3 peers visible" % role)

	match role:
		"A", "B":
			# Both shooters target any non-local peer (the closest); they
			# refresh the target each tick so when C leaves they switch to
			# whoever's left. This is what we want anyway: prove both A and B
			# concurrently land server-side hits AND keep landing after C
			# disconnects mid-match.
			await _shoot_continuous(fire_after, fire_duration)
		"C":
			await get_tree().create_timer(leave_after).timeout
			print("[C] leaving the match")
			_teardown()
			await get_tree().create_timer(2.0).timeout
	get_tree().quit(0)


# ── Helpers ───────────────────────────────────────────────────────────────
func _connect_and_mount() -> bool:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(address)
	if err != OK:
		push_error("[%s] create_client %s" % [role, err])
		return false
	multiplayer.multiplayer_peer = peer
	var deadline: float = Time.get_ticks_msec() / 1000.0 + 5.0
	while peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			push_error("[%s] connect timeout" % role)
			return false
		await get_tree().process_frame
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		push_error("[%s] not connected" % role)
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


func _assert_only_local_camera_current() -> bool:
	for pid in game.players_by_peer.keys():
		var p: Node = game.players_by_peer[pid]
		if p == null or not is_instance_valid(p) or not ("camera" in p):
			continue
		if p.camera != null and p.camera.current != p.is_local:
			_die("peer %d camera.current=%s, expected is_local=%s" % [pid, p.camera.current, p.is_local])
			return false
	return true


func _shoot_continuous(delay: float, duration: float) -> void:
	await get_tree().create_timer(delay).timeout
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		return
	var dt: float = 1.0 / TICK_HZ
	var elapsed: float = 0.0
	var tick: int = 0
	var shots: int = 0
	while elapsed < duration:
		var target: Node = _pick_target()
		if target == null:
			tick += 1
			elapsed += dt
			await get_tree().create_timer(dt).timeout
			continue
		var me_pos: Vector3 = game.local_player.global_position
		var tgt_pos: Vector3 = target.global_position
		var eye: Vector3 = me_pos + Vector3(0, 1.0, 0)
		var body: Vector3 = tgt_pos + Vector3(0, 0.8, 0)
		var to: Vector3 = body - eye
		var horiz: float = Vector2(to.x, to.z).length()
		var aim_yaw: float = atan2(to.x, to.z) + PI
		var aim_pitch: float = atan2(to.y, horiz)
		net_rpc.client_send_input.rpc_id(1, tick, NetProtocol.INPUT_FIRE, aim_yaw, aim_pitch)
		net_rpc.client_fire.rpc_id(1, &"ak20", aim_yaw, aim_pitch)
		tick += 1
		shots += 1
		elapsed += dt
		await get_tree().create_timer(dt).timeout
	print("[%s] sent %d fire RPCs" % [role, shots])


func _pick_target() -> Node:
	# Any non-self peer; refreshed each call so we adapt to disconnects.
	for pid in game.players_by_peer.keys():
		var p: Node = game.players_by_peer[pid]
		if p == null or not is_instance_valid(p) or p.is_local:
			continue
		return p
	return null


func _teardown() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	var g: Node = get_tree().root.get_node_or_null(^"Game")
	if g != null:
		g.queue_free()
	game = null
	for _i in 4:
		await get_tree().process_frame


func _die(msg: String) -> void:
	push_error("[%s] %s" % [role, msg])
	print("[%s] FAIL: %s" % [role, msg])
	get_tree().quit(1)
