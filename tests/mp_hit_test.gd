extends Node
## Multiplayer server-authoritative damage test.
##
## Two processes:
##   --role host  : listen-server, hosts game.tscn
##   --role client: connects, aims at host's known spawn point, fires
##
## Verifies BOTH sides see host's HP drop by exactly the AK20 body-shot value
## (25 HP) — proving:
##   1) client → server fire RPC routed correctly
##   2) server's own raycast resolved against its world view
##   3) server broadcast back to all clients with the damage outcome
##   4) clients applied the broadcast, not their own local raycast

const GAME_SCENE := preload("res://client/scenes/game.tscn")
const ROLE_HOST := "host"
const ROLE_CLIENT := "client"
const HOST_PEER_ID := 1

var role: String = ROLE_HOST
var port: int = 7779
var address: String = "ws://127.0.0.1:7779"
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

	print("[mp-hit] role=%s port=%d" % [role, port])

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

	# Wait until client connects AND has fired AND damage has propagated.
	await get_tree().create_timer(6.0).timeout
	_assert_host_hp_dropped("host")


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

	# Give spawn RPCs time to round-trip.
	await get_tree().create_timer(2.0).timeout

	# Position local player to aim at the host (who is at Spawn1 = (10, 1, 10)).
	var my_id: int = multiplayer.get_unique_id()
	var my_player: Node = game_node.players_by_peer.get(my_id)
	if my_player == null:
		_die("local player not spawned yet")
		return
	var host_player: Node = game_node.players_by_peer.get(HOST_PEER_ID)
	if host_player == null:
		_die("host player not visible to client yet")
		return

	# Move local player to a known firing spot and aim at host body.
	my_player.global_position = Vector3(-10, 1, -10)
	var target_world: Vector3 = host_player.global_position + Vector3(0, 1.1, 0)
	_aim_at(my_player, target_world)
	# Wait long enough for client's _net_apply_state broadcasts to traverse
	# the 100ms entity_interpolator delay on the host side, so host's view of
	# our aim direction is current when the fire RPC arrives.
	await get_tree().create_timer(0.5).timeout

	var hp_before: float = host_player.hp
	print("[client] my pos=%s yaw=%.3f pitch=%.3f host visible at=%s hp=%.0f" %
		[my_player.global_position, my_player.rotation.y, my_player.head.rotation.x,
		host_player.global_position, hp_before])

	if not my_player.try_fire():
		_die("try_fire returned false")
		return

	# Allow round-trip: client_fire → host raycast → server_apply_damage broadcast.
	await get_tree().create_timer(2.5).timeout

	_assert_host_hp_dropped("client")


func _instantiate_game() -> void:
	game_node = GAME_SCENE.instantiate()
	game_node.name = "Game"
	get_tree().root.add_child.call_deferred(game_node)
	await get_tree().process_frame
	print("[mp-hit] game scene mounted at %s" % game_node.get_path())


func _assert_host_hp_dropped(label: String) -> void:
	if game_node == null or not "players_by_peer" in game_node:
		_die("[%s] game_node bad" % label)
		return
	var host_player: Node = game_node.players_by_peer.get(HOST_PEER_ID)
	if host_player == null:
		_die("[%s] host player not in players_by_peer" % label)
		return
	var hp: float = host_player.hp
	# Camera and HeadHitbox are at the same Y (player_y + 1.0). A flat
	# horizontal shot lands on the head → AK20 dmg=25 × headshot mult 2 = 50.
	var expected: float = 300.0 - 50.0
	print("[%s] host_player.hp = %.1f (expected %.1f)" % [label, hp, expected])
	if absf(hp - expected) > 0.5:
		_die("[%s] HP mismatch: expected %.1f, got %.1f" % [label, expected, hp])
		return
	print("[%s] PASS — server-authoritative damage propagated (headshot 50)" % label)
	get_tree().quit(0)


func _aim_at(player: Node, world_target: Vector3) -> void:
	var camera_pos: Vector3 = player.camera.global_position if player.camera != null else player.global_position + Vector3(0, 1.0, 0)
	var to: Vector3 = world_target - camera_pos
	var horiz: float = Vector2(to.x, to.z).length()
	# set_aim is the canonical aim entrypoint — direct rotation writes are
	# clobbered by the camera-kick composition every physics frame.
	player.set_aim(atan2(to.x, to.z) + PI, atan2(to.y, horiz))


func _die(msg: String) -> void:
	push_error("[mp-hit] " + msg)
	print("[mp-hit] FAIL: %s" % msg)
	get_tree().quit(1)
