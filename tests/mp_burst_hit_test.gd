extends Node
## Listen-host burst-fire regression test.
##
## Repro target: remote client empties several AK20 shots into the host, but
## the host only takes the first hit because the host-side mirror never ticks
## `time_until_next_shot` back down. This test fires a short burst and asserts
## the host loses HP multiple times, not just once.

const GAME_SCENE := preload("res://client/scenes/game.tscn")
const ROLE_HOST := "host"
const ROLE_CLIENT := "client"
const HOST_PEER_ID := 1
const TICK_DT := 1.0 / 30.0

var role: String = ROLE_HOST
var port: int = 9219
var address: String = "ws://127.0.0.1:9219"
var game_node: Node = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		match args[i]:
			"--role":
				if i + 1 < args.size():
					role = args[i + 1]
			"--port":
				if i + 1 < args.size():
					port = int(args[i + 1])
			"--address":
				if i + 1 < args.size():
					address = args[i + 1]

	print("[mp-burst] role=%s port=%d" % [role, port])
	if role == ROLE_HOST:
		await _run_host()
	else:
		await _run_client()


func _run_host() -> void:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		_die("create_server failed: %s" % err)
		return
	multiplayer.multiplayer_peer = peer
	print("[host] listening on :%d" % port)
	await _instantiate_game()
	await get_tree().create_timer(8.0).timeout
	_assert_host_took_burst_damage("host")


func _run_client() -> void:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(address)
	if err != OK:
		_die("create_client failed: %s" % err)
		return
	multiplayer.multiplayer_peer = peer

	var deadline: float = Time.get_ticks_msec() / 1000.0 + 5.0
	while peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			_die("connect timeout")
			return
		await get_tree().process_frame
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		_die("not connected, status=%d" % peer.get_connection_status())
		return
	print("[client] connected, peer_id=%d" % multiplayer.get_unique_id())

	await _instantiate_game()
	if not await _wait_for_peers(2, 5.0):
		_die("peer count never reached 2")
		return
	await get_tree().create_timer(1.0).timeout

	var my_id: int = multiplayer.get_unique_id()
	var me: Node = game_node.players_by_peer.get(my_id)
	var host_player: Node = game_node.players_by_peer.get(HOST_PEER_ID)
	if me == null or host_player == null:
		_die("client missing me/host player")
		return

	me.global_position = Vector3(-10, 1, -10)
	var fired_count: int = 0
	for i in range(6):
		if not is_instance_valid(host_player):
			_die("host player invalid mid-burst")
			return
		_aim_at(me, host_player.global_position + Vector3(0, 0.45, 0))
		await get_tree().physics_frame
		if me.try_fire():
			fired_count += 1
		await get_tree().create_timer(0.15).timeout
	print("[client] burst fired_count=%d" % fired_count)
	if fired_count < 4:
		_die("burst fired too few shots: %d" % fired_count)
		return

	await get_tree().create_timer(2.0).timeout
	_assert_host_took_burst_damage("client")


func _instantiate_game() -> void:
	game_node = GAME_SCENE.instantiate()
	game_node.name = "Game"
	get_tree().root.add_child.call_deferred(game_node)
	await get_tree().process_frame
	print("[mp-burst] game scene mounted at %s" % game_node.get_path())


func _wait_for_peers(want: int, seconds: float) -> bool:
	var deadline: float = Time.get_ticks_msec() / 1000.0 + seconds
	while Time.get_ticks_msec() / 1000.0 < deadline:
		if game_node != null and "players_by_peer" in game_node and game_node.players_by_peer.size() == want:
			return true
		await get_tree().process_frame
	return false


func _assert_host_took_burst_damage(label: String) -> void:
	var host_player: Node = game_node.players_by_peer.get(HOST_PEER_ID)
	if host_player == null:
		_die("[%s] host player missing" % label)
		return
	var hp: float = host_player.hp
	print("[%s] host hp=%.1f" % [label, hp])
	# One accepted AK20 body shot leaves 275 or 250 depending on hitbox.
	# We require clear multi-hit evidence.
	if hp > 225.0:
		_die("[%s] expected burst damage (>1 accepted hit), got hp=%.1f" % [label, hp])
		return
	print("[%s] PASS — host took burst damage across multiple shots" % label)
	get_tree().quit(0)


func _aim_at(player: Node, world_target: Vector3) -> void:
	var camera_pos: Vector3 = player.camera.global_position if player.camera != null else player.global_position + Vector3(0, 1.0, 0)
	var to: Vector3 = world_target - camera_pos
	var horiz: float = Vector2(to.x, to.z).length()
	player.set_aim(atan2(to.x, to.z) + PI, atan2(to.y, horiz))


func _die(msg: String) -> void:
	push_error("[mp-burst] " + msg)
	print("[mp-burst] FAIL: %s" % msg)
	get_tree().quit(1)
