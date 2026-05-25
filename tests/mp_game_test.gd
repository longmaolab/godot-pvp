extends Node
## Multiplayer-mode end-to-end test.
##
## --role host  : starts a WS server on a configurable port, instantiates
##                game.tscn, waits N seconds, asserts >= 2 players.
## --role client: connects to the WS server, instantiates game.tscn, waits
##                N seconds, asserts >= 2 players.
##
## Run host:    godot --headless --path . tests/mp_game_test.tscn -- --role host --port 7778
## Run client:  godot --headless --path . tests/mp_game_test.tscn -- --role client --address ws://127.0.0.1:7778

const GAME_SCENE := preload("res://client/scenes/game.tscn")
const ROLE_HOST := "host"
const ROLE_CLIENT := "client"

var role: String = ROLE_HOST
var port: int = 7778
var address: String = "ws://127.0.0.1:7778"
var wait_seconds: float = 4.0
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
			"--wait":
				if i + 1 < args.size():
					wait_seconds = float(args[i + 1])

	print("[mp-test] role=%s port=%d address=%s" % [role, port, address])

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
	print("[host] listening on :%d, peer_id=%d" % [port, multiplayer.get_unique_id()])

	await _instantiate_game()
	await _wait_and_assert("host")


func _run_client() -> void:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(address)
	if err != OK:
		_die("create_client failed: %s" % err)
		return
	multiplayer.multiplayer_peer = peer
	print("[client] connecting to %s" % address)

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
	await _wait_and_assert("client")


func _instantiate_game() -> void:
	game_node = GAME_SCENE.instantiate()
	# Force node name "Game" so RPC paths match on host and client.
	game_node.name = "Game"
	get_tree().root.add_child.call_deferred(game_node)
	# Wait one frame so the node is in the tree before we report its path.
	await get_tree().process_frame
	print("[mp-test] game scene mounted at %s" % game_node.get_path())


func _wait_and_assert(label: String) -> void:
	await get_tree().create_timer(wait_seconds).timeout
	if game_node == null:
		_die("[%s] game node missing" % label)
		return
	if not "players_by_peer" in game_node:
		_die("[%s] game node has no players_by_peer dict" % label)
		return
	var count: int = game_node.players_by_peer.size()
	var peers: Array = game_node.players_by_peer.keys()
	print("[%s] players_by_peer: %d entries  → %s" % [label, count, peers])
	# Print per-player flags so DS-mode bugs (local_player never bound) surface
	# even if just a single peer is connected.
	for pid in peers:
		var p: Node = game_node.players_by_peer[pid]
		if p == null:
			continue
		print("  peer %d: is_local=%s is_human=%s remote_input=%s snapshot_only=%s" % [
			pid, p.is_local, p.is_human_input, p.use_remote_input, p.is_snapshot_only])
		if "camera" in p and p.camera != null and p.camera.current != p.is_local:
			_die("[%s] peer %d camera.current=%s, expected is_local=%s" % [
				label, pid, p.camera.current, p.is_local])
			return
	print("  game.local_player = %s" % str(game_node.local_player))
	# DS clients connect to a server they don't own — only one player exists
	# locally (their own). Listen-host expects ≥ 2.
	var min_expected: int = 1 if (game_node.local_player != null and game_node.local_player.is_snapshot_only) else 2
	if count < min_expected:
		_die("[%s] expected >= %d players, got %d" % [label, min_expected, count])
		return
	print("[%s] PASS" % label)
	get_tree().quit(0)


func _die(msg: String) -> void:
	push_error("[mp-test] " + msg)
	print("[mp-test] FAIL: %s" % msg)
	get_tree().quit(1)
