extends Node
## Listen-host collision-authority regression test.
##
## Before the fix, the host accepted a remote peer's `_net_apply_state(pos)`
## directly and rendered that peer by writing `global_position = pos`. That let
## a client bypass CharacterBody3D collision entirely from the host's point of
## view: walls, obstacles, and players were all phase-through.
##
## This test proves the host now ignores raw transform pushes for remote peers
## instead of blindly accepting teleports from listen-host clients.

const GAME_SCENE := preload("res://client/scenes/game.tscn")
const ROLE_HOST := "host"
const ROLE_CLIENT := "client"
const HOST_PEER_ID := 1
const INPUT_FORWARD := 1 << 0
const TELEPORT_POS := Vector3(123.0, 50.0, 123.0)

var role: String = ROLE_HOST
var port: int = 9233
var address: String = "ws://127.0.0.1:9233"
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
	print("[mp-coll] role=%s port=%d" % [role, port])
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
	if not await _wait_for_peer_count(2, 5.0):
		_die("host never saw 2 players")
		return
	var remote: Node = _first_remote_player()
	if remote == null:
		_die("host missing remote player")
		return
	var start: Vector3 = remote.global_position
	print("[host] remote start=%s" % str(start))
	await get_tree().create_timer(2.5).timeout
	var finish: Vector3 = remote.global_position
	print("[host] remote finish=%s" % str(finish))
	if finish.distance_to(TELEPORT_POS) < 5.0:
		_die("host accepted raw transform push: finish=%s teleport=%s" % [str(finish), str(TELEPORT_POS)])
		return
	if finish.y > 3.0:
		_die("remote floated/teleported vertically: y=%.2f" % finish.y)
		return
	print("[host] PASS — ignored raw transform push")
	get_tree().quit(0)


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
	if not await _wait_for_peer_count(2, 5.0):
		_die("client never saw 2 players")
		return
	var me: Node = game_node.local_player
	if me == null:
		_die("client missing local player")
		return
	# Disable the normal local `_physics_process` so our manual test RPCs are the
	# only network traffic affecting the host's mirror.
	me.set_physics_process(false)
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		_die("NetRpc missing")
		return
	for tick in range(20):
		net_rpc.client_send_input.rpc_id(1, tick, INPUT_FORWARD, 0.0, 0.0)
		me._net_apply_state.rpc_id(1, TELEPORT_POS, 0.0, 0.0)
		await get_tree().create_timer(1.0 / 30.0).timeout
	print("[client] PASS — sent forward-input frames + teleport spoof attempts")
	await get_tree().create_timer(3.0).timeout
	get_tree().quit(0)


func _instantiate_game() -> void:
	game_node = GAME_SCENE.instantiate()
	game_node.name = "Game"
	get_tree().root.add_child.call_deferred(game_node)
	await get_tree().process_frame
	print("[mp-coll] game scene mounted at %s" % game_node.get_path())


func _wait_for_peer_count(want: int, seconds: float) -> bool:
	var deadline: float = Time.get_ticks_msec() / 1000.0 + seconds
	while Time.get_ticks_msec() / 1000.0 < deadline:
		if game_node != null and "players_by_peer" in game_node and game_node.players_by_peer.size() == want:
			return true
		await get_tree().process_frame
	return false


func _first_remote_player() -> Node:
	for pid in game_node.players_by_peer.keys():
		if int(pid) != HOST_PEER_ID:
			return game_node.players_by_peer[pid]
	return null


func _die(msg: String) -> void:
	push_error("[mp-coll] " + msg)
	print("[mp-coll] FAIL: %s" % msg)
	get_tree().quit(1)
