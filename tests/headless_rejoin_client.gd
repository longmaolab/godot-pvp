extends Node
## Reconnect regression test. Connect to DS, spawn, disconnect cleanly, then
## reconnect on the same process. Asserts: second spawn happens without
## getting stuck on the connecting overlay.

const GAME_SCENE_PATH := "res://client/scenes/game.tscn"

var address: String = "ws://127.0.0.1:9202"
var first_spawn_ok: bool = false
var second_spawn_ok: bool = false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--address" and i + 1 < args.size():
			address = args[i + 1]

	# ── First connection ──────────────────────────────────────────────────
	if not await _connect_and_check(1):
		_die("first connect failed")
		return
	first_spawn_ok = true
	print("[rejoin] FIRST connect OK")

	# Tear down (simulates clicking "Main Menu" in pause_menu).
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	# Free the game scene like change_scene_to_file would.
	var game := get_tree().root.get_node_or_null(^"Game")
	if game != null:
		game.queue_free()
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	print("[rejoin] disconnected, waiting 0.5s before rejoin")

	# ── Second connection ─────────────────────────────────────────────────
	if not await _connect_and_check(2):
		_die("rejoin failed — first client cannot reconnect")
		return
	second_spawn_ok = true
	print("[rejoin] SECOND connect OK — rejoin works")
	get_tree().quit(0)


func _connect_and_check(attempt: int) -> bool:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(address)
	if err != OK:
		push_error("[rejoin] attempt %d create_client failed: %s" % [attempt, err])
		return false
	multiplayer.multiplayer_peer = peer

	var deadline: float = Time.get_ticks_msec() / 1000.0 + 5.0
	while peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			push_error("[rejoin] attempt %d connect timeout" % attempt)
			return false
		await get_tree().process_frame
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		push_error("[rejoin] attempt %d not connected" % attempt)
		return false
	print("[rejoin] attempt %d connected as peer %d" % [attempt, multiplayer.get_unique_id()])

	# Mount the real game scene.
	var game_scene: PackedScene = load(GAME_SCENE_PATH) as PackedScene
	var game: Node = game_scene.instantiate()
	game.name = "Game"
	get_tree().root.add_child.call_deferred(game)
	await get_tree().process_frame

	# Wait up to 3s for our local player to materialize.
	var spawn_deadline: float = Time.get_ticks_msec() / 1000.0 + 3.0
	while Time.get_ticks_msec() / 1000.0 < spawn_deadline:
		var g: Node = get_tree().root.get_node_or_null(^"Game")
		if g != null and g.get("local_player") != null:
			print("[rejoin] attempt %d local_player materialized" % attempt)
			return true
		await get_tree().process_frame
	push_error("[rejoin] attempt %d local_player never spawned" % attempt)
	return false


func _die(msg: String) -> void:
	push_error(msg)
	print("[rejoin] FAIL: %s" % msg)
	get_tree().quit(1)
