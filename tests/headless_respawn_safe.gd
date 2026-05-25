extends Node
## DS respawn-safety integration test. Existing run_respawn_test.sh proves
## the death → 3s timer → respawn broadcast chain. THIS test extends it with
## the two safety properties players actually feel:
##
##   1. ANTI-SPAWN-KILL POSITIONING: when B dies, the server picks a spawn
##      far from A so A can't camp the corpse. Asserts: respawn pos and A's
##      position differ by >= MIN_SPAWN_DIST.
##   2. POST-RESPAWN INVINCIBILITY: after respawning, B is invincible for
##      ~2.5s (RESPAWN_INVINCIBILITY_SEC). During this window the server's
##      raycast may still LAND on B's hitbox but no `[server] hit:` line
##      should be emitted (apply_damage early-returns).
##
## Roles:
##   --role A   shooter; kills B then keeps firing for 5s
##   --role B   victim
##
## Time budget: 12s.

const GAME_SCENE_PATH := "res://client/scenes/game.tscn"
const TICK_HZ := 30.0
const MIN_SPAWN_DIST := 8.0  # blank map's corner-to-corner ≈ 28; same point would be 0

var role: String = "A"
var address: String = "ws://127.0.0.1:9206"
var fire_seconds: float = 9.0

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
	if game.local_player != null:
		game.local_player.is_human_input = false

	if not await _wait_for_peer_count(2, 5.0):
		_die("peer count never reached 2")
		return
	await get_tree().create_timer(0.4).timeout

	if role == "A":
		await _run_shooter()
	else:
		await _run_victim()
	get_tree().quit(0)


func _run_shooter() -> void:
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		_die("A: no NetRpc")
		return
	var dt: float = 1.0 / TICK_HZ
	var tick: int = 0
	var elapsed: float = 0.0
	# Fire continuously at whoever the non-local peer is right now.
	while elapsed < fire_seconds:
		var target: Node = _other_peer()
		if target == null:
			tick += 1; elapsed += dt
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
		elapsed += dt
		await get_tree().create_timer(dt).timeout
	# Final dump: A's own position so the shell can verify B's respawn moved far.
	print("[A] final pos=%s" % str(game.local_player.global_position))


func _run_victim() -> void:
	# B doesn't fire. Just observe and log spawn/respawn transitions.
	var dt: float = 1.0 / TICK_HZ
	var elapsed: float = 0.0
	var last_pos: Vector3 = game.local_player.global_position
	var teleports: Array = []   # Each entry: [t_seconds, from, to]
	print("[B] initial pos=%s" % str(last_pos))
	while elapsed < fire_seconds:
		var pos: Vector3 = game.local_player.global_position
		if last_pos.distance_to(pos) > 5.0:
			teleports.append([elapsed, last_pos, pos])
			print("[B] RESPAWNED t=%.2f  %s → %s" % [elapsed, str(last_pos), str(pos)])
		last_pos = pos
		elapsed += dt
		await get_tree().create_timer(dt).timeout
	print("[B] final pos=%s teleports=%d" % [str(game.local_player.global_position), teleports.size()])


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
